# How to drive a chart that calls out

This guide shows you how to run an execution whose chart calls out to your
host: it invokes a service and waits for the answer. The example is the loan
chart from [How to persist an execution and resume it in
another process](persist-and-resume.md), which invokes a hold check when a
copy of a book is lent to a patron.

`Executions` steps an execution once. A chart that invokes a service is not
finished when that step returns - it is waiting for an answer it cannot fetch
for itself, and every host that has embedded this package has written the
same loop on top. `StatifierPersistence.Driver` is that loop.

## Before you start

The snippets below use two values the persist-and-resume guide makes: `store`
and `machine`, the storage handle and the compiled loan chart you stored under
its content hash (its "Store the compiled chart" step). You also need
`execution_id`, the id you choose for the loan, such as `"loan_01H8"`. The
snippets use the `Statifier.Invoke.Types` and `Statifier.Send.Types` modules
by their full names.

## Build the driver

Give `Driver.new/3` the store, the machine and the seams to your host:

```elixir
driver =
  StatifierPersistence.Driver.new(store, machine,
    dispatch: fn type, params, _context -> MyApp.Holds.perform(type, params) end,
    effects: fn effect, _context -> MyApp.Timers.consume(effect) end,
    invoke_types: Statifier.Invoke.Types.new(types: ["myapp:check_holds"]),
    send_types: Statifier.Send.Types.from_send_types(%{"myapp:remind" => MyApp.Reminders}),
    serialization: {MyApp.ExecutionLock, MyApp.ExecutionLock}
  )
```

The two registrations, `invoke_types:` and `send_types:`, are given once, to
`new/3`: the driver carries them inside `initialize:` on the create and
stamps them on every step after it.

## Create the execution and send it events

```elixir
{:ok, execution, state} = StatifierPersistence.Driver.create(driver, execution_id)

{:ok, execution, state} =
  StatifierPersistence.Driver.send_event(
    driver,
    execution_id,
    Statifier.Event.external("loan.due")
  )
```

One call is one durable step, every effect through your `effects:` executor,
every `<invoke>` through your `dispatch:` fun inside that same step, and then
one further durable step per answer until the chart rests.

`{:ok, donedata}` from `dispatch:` answers `done.invoke.<id>`;
`{:error, failure}` answers `error.communication.invoke.<id>` with
`Statifier.Session.failed_invocation/3`'s own `reason`/`attempts`/`detail`
payload, and means permanently failed rather than "retry".

Both events are built field for field from the two doors `Statifier.Session`
gives a handler-backed invocation's host, `origin` and `origintype` included,
so the same chart sees the same event whether it runs in a session or out of
storage. That is asserted rather than claimed:
`test/statifier_persistence/driver_session_conformance_test.exs` answers one
document both ways and compares the `_event` each chart saw.

An answer whose invocation the chart has since cancelled is dropped, per spec
6.4.3, and a chart whose answer re-arms its own call is bounded by
`max_turns:` rather than driven forever.

## Register guard functions

If a chart's `cond` and `expr` may call guard functions your host registers
(statifier's `:function_providers`), give `function_providers:` to `new/3` the
same way. The driver stamps the list on the create and on every step, so a
resumed execution evaluates them with no call to
`Statifier.MachineState.put_function_providers/2` of your own. A durable
subchart child the driver creates does not inherit the list.

A list that does not resolve is refused with
`{:error, {:function_providers, reason}}` before any lock, load or write.
`start_child_at/6`, the fan-out door, refuses it in its own shape,
`{:refused, {:function_providers, reason}}`, before any child is created.

## Fan one invocation out over N children

A durable subchart is one child per `<invoke>`, created inside the parent's
own step. An `<invoke>` that maps over a list is N of them - say, one child
per copy on a patron's reading list - and N creates cannot hold the parent's
exclusion, so the children are started afterwards: one call per child, from
whatever job picks it up.

```elixir
StatifierPersistence.Driver.start_child_at(driver, parent_execution_id, effect, index, count,
  policy: :all
)
```

`effect` is the resolved `Statifier.Effect.Invoke` (or the whole
`{:start_child, resolved, {:invoke, invoke}}` instruction), `index` is the
child's 0-based position, and `count` is N. The call is idempotent on the
child's derived execution id, so a re-delivered start adopts the child it
already created instead of making a second one. Scheduling those calls is a
job runner's business, not this package's.

Each child then runs as an ordinary execution. When one reaches a terminal
status its answer is stored on its own execution record, and a settlement
section under the **parent's** exclusion asks - through an indexed status
projection, never a listing of whole records - whether all N have. Only the
settlement that finds them all terminal assembles the dense, index-ordered
list and answers the parent's ordinary door, once:

```elixir
[
  %{"index" => 0, "status" => "completed", "donedata" => %{"id" => "copy_1"}},
  %{"index" => 1, "status" => "failed", "failure" => %{"reason" => "on_hold", ...}},
  %{"index" => 2, "status" => "cancelled"}
]
```

### Cancel the rest when one child fails

`policy: :first_error` cancels the rest as soon as one child fails: the
started siblings through the cascading cancel, and the ones whose start job
has not run yet through the `child_canceller:` seam, which is handed the
parent execution id, the invocation id, and the indices with no execution.
Both kinds read `"cancelled"` at their index in the same list.

### Let a child fail on its own word

A child fails on its own word, with no host in the loop, by settling in a
**failure-classed final** - a top-level `<final>` whose `<donedata>` carries
the reserved key `statifier_persistence:execution_status` set to `"failed"`:

```xml
<final id="on_hold">
  <donedata>
    <param name="statifier_persistence:execution_status" expr="'failed'"/>
    <param name="reason" expr="hold_reason"/>
  </donedata>
</final>
```

That step is an ordinary successful one; the execution record takes `:failed`
with the `failure` string `"failed_final"`, and the whole `<donedata>` - tag
included, alongside whatever else the final carries - reaches the parent's
list verbatim. Macrostep-budget exhaustion is the other route to `:failed`,
and the `failure` string is what tells the two apart. An unhandled `error.*`
event is not a route: a chart that cannot continue stays `:active` until its
author routes the error to a final. See `StatifierPersistence.Executions` for
the full rule.

Before 0.12.0 that key was spelled `statifier_persistence:run_status`. Both
spellings are read for one release: in 0.12.0 the new key wins where both are
present and the old one logs a deprecation line, and 0.13.0 reads only
`statifier_persistence:execution_status` (ADR-0011 decision 4).

### Check your adapter can settle children

An adapter that cannot store a child's answer, or cannot answer the status
projection, is refused at open - a child whose invocation could never be
settled is not started. On the Ecto adapter both arrive with the V03
migration.
