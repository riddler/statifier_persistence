# How to persist an execution and resume it in another process

This guide shows you how to store an execution after every step and carry it
on from another process, after a restart or a deploy, with nothing but its
execution id. The example lends a copy of a book to a patron: check the copy
for holds before it goes out, keep it on loan until it comes due, and close the
loan when it is returned. The whole execution is four calls, and no process
holds the chart between them.

## Define the chart

```elixir
alias Statifier.{Chart, Event, Machine, MachineState}
alias Statifier.Invoke.Types, as: InvokeTypes
alias Statifier.Send.Types, as: SendTypes
alias StatifierPersistence.{Executions, Storage}

source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="checking_holds">
  <state id="checking_holds">
    <invoke type="myapp:check_holds" id="check_holds"/>
    <transition event="done.invoke.check_holds" target="on_loan"/>
  </state>
  <state id="on_loan">
    <transition event="loan.due" target="due"/>
  </state>
  <state id="due">
    <transition event="loan.returned" target="returned"/>
  </state>
  <final id="returned"/>
</scxml>
"""
```

## Store the compiled chart

Compile the chart once and store its bytes under its own content hash.
Nothing is keyed by a name you choose: the identity comes off the compiled
`Machine`, which is what makes the guard unskippable.

```elixir
{:ok, machine} = Statifier.compile(source)
{:ok, chart_blob} = Chart.to_binary(machine)

{:ok, store} = Storage.new(StatifierPersistence.Storage.InMemory, [])
:ok = Storage.save_chart(store, machine, chart_blob)
```

## Connect your host to the effects

Every effect a step emits reaches your host through one seam: a module
implementing `StatifierPersistence.Executor`, or an arity-2 fun. Effects
arrive one at a time, in list order, as `{tag, payload}` tuples. This one does
the least a real host could do with the hold check:

```elixir
executor = fn
  {:invoke, %Statifier.Effect.Invoke{type: "myapp:check_holds"} = invoke}, ctx ->
    # your own hold check, keyed for idempotency by execution and invocation
    MyApp.Holds.check(ctx.execution_id, invoke.invoke_id)
    :ok

  _effect, _ctx ->
    :ok
end

stamps = [
  invoke_types: InvokeTypes.new(types: ["myapp:check_holds"]),
  send_types: SendTypes.from_send_types(%{"myapp:remind" => MyApp.Reminders})
]

opts = [executor: executor] ++ stamps
```

`invoke_types:` and `send_types:` are your host's registrations: the
`<invoke>` and `<send>` types it implements beyond the built-in ones. They are
stamped onto the position rather than stored with it, so pass them on every
call. A `<send>` whose type is not registered is rejected with
`error.execution`. The third stamp, `routes:`, is a per-step claim about which
`<send>` targets are live; this chart sends nothing, so leave it unset, which
means "no determination made".

## Create the execution

Call `create/4`. It initializes the chart, hands the resulting effects to the
executor, and persists the quiescent position under an execution id you
choose - here the loan's own key.

Pass the registrations inside `initialize:`. A create has no stored position
to stamp, so it reads them only from there; passed beside `executor:` on this
call they would be ignored, and the `<invoke>` in the initial configuration
would go out unregistered.

```elixir
{:ok, execution, state} =
  Executions.create(store, "loan_01H8", machine, executor: executor, initialize: stamps)

#=> execution.status == :active, active leaf state "checking_holds"
```

## Step the execution with each event

Deliver each later event with one `step/5`: liveness check, guarded load,
step, effects out through the seam, persist. Between calls there is no live
process and no in-memory position - only the execution record.

```elixir
{:ok, execution, state} =
  Executions.step(
    store,
    "loan_01H8",
    machine,
    Event.external("done.invoke.check_holds", invokeid: "check_holds"),
    opts
  )

#=> execution.status == :active, active leaf state "on_loan"
```

## Resume it in another process

Nothing above kept state in the beam, so a restart or a deploy in the middle
of the execution changes nothing about how it continues. Given only the
execution id, fetch the record, fetch the chart bytes it names, and recompile:

```elixir
{:ok, record} = Storage.fetch_execution(store, "loan_01H8")
{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, record.content_hash)
{:ok, rebooted} = Chart.from_binary(blob)
```

Step with `rebooted`, the machine compiled afresh from the stored bytes, not
one carried over from before the restart. A position is only meaningful
against the exact chart revision that produced it, because Statifier interns
state ids to indices at compile time, and the identity guard enforces that on
every load: step an execution with a machine compiled from a *changed* chart
and it refuses with `{:error, {:identity_mismatch, stored, supplied}}` rather
than silently resuming the wrong configuration.

```elixir
{:ok, execution, state} =
  Executions.step(store, "loan_01H8", rebooted, Event.external("loan.due"), opts)

#=> execution.status == :active, active leaf state "due"
```

```elixir
{:ok, execution, state} =
  Executions.step(store, "loan_01H8", rebooted, Event.external("loan.returned"), opts)

#=> execution.status == :completed, no active leaf states
```

`:completed` is reached only by the chart reaching a final state - the
lifecycle consumes the interpreter's `:done` itself and never hands it to
your executor. To end an execution from the host instead, call
`Executions.fail/4`, the one host-driven terminal transition. A step
delivered to a terminal execution comes back `{:discarded, execution}` rather
than raising.

## Read the configuration back

To read the configuration back as state ids, as the snippets' comments show
it:

```elixir
state
|> MachineState.active_leaf_states()
|> Enum.map(&Machine.id(state.machine, &1))
|> Enum.sort()
```

## What stays your host's job

Two things the loop deliberately does not do. Effect delivery is
at-least-once: a crash between step and persist re-drives the same event and
re-emits the same effects with identical deterministic keys, and the loop
never dedupes - make your effect handling idempotent on that key. And a
resumed execution restores position, not liveness: re-establish pending
timers and in-flight invocations from your own durable rows.
[Surviving a restart](../restart-demo.md) walks a demo embedder through both.

## The modules this guide uses

| Module | Role |
|---|---|
| `StatifierPersistence.Storage` | The identity-guarded facade: charts, positions, execution records. Every load is guarded; there is no unguarded path |
| `StatifierPersistence.Storage.Adapter` | The behaviour a backing store implements. `Storage.InMemory` is the reference one, `Storage.Ecto` the Postgres one (on [another backend](../non-postgres-backends.md), minus the lock and the listings) |
| `StatifierPersistence.Executions` | The lifecycle: `create/4`, `step/5`, `fail/4`, in ADR-0004's fixed order |
| `StatifierPersistence.Driver` | Drive-to-quiescence over `Executions`: performs the chart's `<invoke>` calls and steps each answer back in |
| `StatifierPersistence.Executor` | The seam every effect crosses on its way to your host |
| `StatifierPersistence.Retention` | `prune/3`: clears the position blob and input log of every execution that ended before a cutoff you choose, and keeps the row ([what a finished execution leaves behind](../retention.md)) |
| `StatifierPersistence.Serialization` | The per-execution ordering strategy the fetch-to-persist tail runs inside; defaults to the adapter's own `lock_execution/3` |
| `StatifierPersistence.Testing.StorageConformance` | The conformance suite - point it at your own adapter to hold it to the same bar |
