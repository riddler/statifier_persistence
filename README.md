# StatifierPersistence

[![CI](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_persistence/)
[![License](https://img.shields.io/hexpm/l/statifier_persistence.svg)](https://github.com/riddler/statifier_persistence/blob/main/LICENSE)

> **Pre-1.0.** Until `statifier_persistence` reaches v1.0, its public surface may change
> between minor releases, sometimes drastically: a release may rename modules,
> callbacks, table columns, telemetry events or error vocabulary with no
> compatibility shim. Every such change is recorded in
> [CHANGELOG.md](CHANGELOG.md) under a bold **Breaking** heading that says what
> to do about it. Pinning to an exact minor - `~> X.Y.0` - is the recommended way
> to consume the package until 1.0. What a host changes for each minor from 0.13
> on is on one page:
> [`docs/upgrading.md`](https://github.com/riddler/statifier_persistence/blob/main/docs/upgrading.md).

Durable stepper and storage adapters for
[Statifier](https://github.com/riddler/statifier-ex).

Documentation lives on [hexdocs](https://hexdocs.pm/statifier_persistence/),
including the [Surviving a restart](docs/restart-demo.md) guide.

Statifier's pure interpreter contract (machine_state, event -> machine_state,
effects) makes a persistence-first execution model possible: load a persisted
position, step it, execute the effects, persist. Hosts running charts that
span days or survive deploys should not need long-lived Session processes at
all - but every host currently hand-rolls the loop, the storage guard, and the
crash semantics. This package is that loop, packaged.

## Installation

```elixir
def deps do
  [
    {:statifier_persistence, "~> 0.19.0"},
    # Optional, for the Postgres adapter:
    {:ecto_sql, "~> 3.10"}
  ]
end
```

## A worked execution

A card-processing transaction: authorize it, capture it before its
capture window closes, settle it. The whole execution is four calls, and no
process holds the chart between them.

```elixir
alias Statifier.{Chart, Event, Machine, MachineState}
alias Statifier.Invoke.Types, as: InvokeTypes
alias Statifier.Send.Types, as: SendTypes
alias StatifierPersistence.{Executions, Storage}

source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorizing">
  <state id="authorizing">
    <invoke type="myapp:authorize" id="authorize"/>
    <transition event="done.invoke.authorize" target="awaiting_capture"/>
  </state>
  <state id="awaiting_capture">
    <transition event="capture.requested" target="settling"/>
  </state>
  <state id="settling">
    <transition event="ack" target="settled"/>
  </state>
  <final id="settled"/>
</scxml>
"""
```

Compile the chart once and store its bytes under its own content hash.
Nothing is keyed by a name you choose: the identity comes off the
compiled `Machine`, which is what makes the guard unskippable.

```elixir
{:ok, machine} = Statifier.compile(source)
{:ok, chart_blob} = Chart.to_binary(machine)

{:ok, store} = Storage.new(StatifierPersistence.Storage.InMemory, [])
:ok = Storage.save_chart(store, machine, chart_blob)
```

Every effect a step emits reaches your host through one seam - a module
implementing `StatifierPersistence.Executor`, or an arity-2 fun. Effects
arrive one at a time, in list order, as `{tag, payload}` tuples. This one
does the least a real host could do with an outbound authorization:

```elixir
executor = fn
  {:invoke, %Statifier.Effect.Invoke{type: "myapp:authorize"} = invoke}, ctx ->
    # your own gateway call, keyed for idempotency by execution and invocation
    MyApp.Payments.authorize(ctx.execution_id, invoke.invoke_id)
    :ok

  _effect, _ctx ->
    :ok
end

stamps = [
  invoke_types: InvokeTypes.new(types: ["myapp:authorize"]),
  send_types: SendTypes.from_send_types(%{"myapp:notify" => MyApp.Notifier})
]

opts = [executor: executor] ++ stamps
```

`invoke_types:` and `send_types:` are your host's registrations: the
`<invoke>` and `<send>` types it implements beyond the built-in ones. They
are stamped onto the position rather than stored with it, so every call
carries them, and a `<send>` whose type is not registered is rejected with
`error.execution`. The third stamp, `routes:`, is a per-step claim about
which `<send>` targets are live; this chart sends nothing, so it is left
unset, which means "no determination made".

`create/4` initializes the chart, hands the resulting effects to the
executor, and persists the quiescent position under an execution id you choose
- here the transaction's own key. A create has no stored position to stamp,
so it reads the registrations only from inside `initialize:`; passed beside
`executor:` on this call they would be ignored, and the `<invoke>` in the
initial configuration would go out unregistered:

```elixir
{:ok, execution, state} =
  Executions.create(store, "txn_01H8", machine, executor: executor, initialize: stamps)

#=> execution.status == :active, active leaf state "authorizing"
```

Each later event is one `step/5`: liveness check, guarded load, step,
effects out through the seam, persist. Between calls there is no live
process and no in-memory position - only the execution record.

```elixir
{:ok, execution, state} =
  Executions.step(
    store,
    "txn_01H8",
    machine,
    Event.external("done.invoke.authorize", invokeid: "authorize"),
    opts
  )

#=> execution.status == :active, active leaf state "awaiting_capture"
```

### Across a restart

Nothing above kept state in the beam, so a deploy in the middle of the
execution changes nothing about how it continues. Given only the execution
id, fetch the record, fetch the chart bytes it names, and recompile:

```elixir
{:ok, record} = Storage.fetch_execution(store, "txn_01H8")
{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, record.content_hash)
{:ok, rebooted} = Chart.from_binary(blob)
```

`rebooted` is compiled afresh from the stored bytes, not carried over
from before the restart, and it is what makes the stored position
readable again: Statifier interns state ids to indices at compile time,
so a position is only meaningful against the exact chart revision that
produced it. The identity guard enforces that on every load. Step an execution
with a machine compiled from a *changed* chart and it refuses with
`{:error, {:identity_mismatch, stored, supplied}}` rather than silently
resuming the wrong configuration.

```elixir
{:ok, execution, state} =
  Executions.step(store, "txn_01H8", rebooted, Event.external("capture.requested"), opts)

#=> execution.status == :active, active leaf state "settling"

{:ok, execution, state} =
  Executions.step(store, "txn_01H8", rebooted, Event.external("ack"), opts)

#=> execution.status == :completed, no active leaf states
```

`:completed` is reached only by the chart reaching a final state - the
lifecycle consumes the interpreter's `:done` itself and never hands it
to your executor. `Executions.fail/4` is the one host-driven terminal
transition, and a step delivered to a terminal execution comes back
`{:discarded, execution}` rather than raising.

To read the configuration back as state ids, as the snippets' comments
show it:

```elixir
state
|> MachineState.active_leaf_states()
|> Enum.map(&Machine.id(state.machine, &1))
|> Enum.sort()
```

### What each module is for

| Module | Role |
|---|---|
| `StatifierPersistence.Storage` | The identity-guarded facade: charts, positions, execution records. Every load is guarded; there is no unguarded path |
| `StatifierPersistence.Storage.Adapter` | The behaviour a backing store implements. `Storage.InMemory` is the reference one, `Storage.Ecto` the Postgres one (on [another backend](docs/non-postgres-backends.md), minus the lock and the listings) |
| `StatifierPersistence.Executions` | The lifecycle: `create/4`, `step/5`, `fail/4`, in ADR-0004's fixed order |
| `StatifierPersistence.Driver` | Drive-to-quiescence over `Executions`: performs the chart's `<invoke>` calls and steps each answer back in |
| `StatifierPersistence.Executor` | The seam every effect crosses on its way to your host |
| `StatifierPersistence.Retention` | `prune/3`: clears the position blob and input log of every execution that ended before a cutoff you choose, and keeps the row ([what a finished execution leaves behind](docs/retention.md)) |
| `StatifierPersistence.Serialization` | The per-execution ordering strategy the fetch-to-persist tail runs inside; defaults to the adapter's own `lock_execution/3` |
| `StatifierPersistence.Testing.StorageConformance` | The conformance suite - point it at your own adapter to hold it to the same bar |

Two things the loop deliberately does not do. Effect delivery is
at-least-once: a crash between step and persist re-drives the same event
and re-emits the same effects with identical deterministic keys, and the
loop never dedupes - idempotency on that key is yours. And a resumed execution
restores position, not liveness: pending timers and in-flight
invocations are re-established by the host, from its own durable rows.
[Surviving a restart](docs/restart-demo.md) walks a demo embedder
through both.

## Driving a chart that calls out

`Executions` steps an execution once. A chart that invokes a service is not
finished
when that step returns - it is waiting for an answer it cannot fetch
for itself, and every host that has embedded this package has written
the same loop on top. `StatifierPersistence.Driver` is that loop:

```elixir
driver =
  StatifierPersistence.Driver.new(store, machine,
    dispatch: fn type, params, _context -> MyApp.perform(type, params) end,
    effects: fn effect, _context -> MyApp.Timers.consume(effect) end,
    invoke_types: Statifier.Invoke.Types.new(types: ["myapp:authorize"]),
    send_types: Statifier.Send.Types.from_send_types(%{"myapp:notify" => MyApp.Notifier}),
    serialization: {MyApp.ExecutionLock, MyApp.ExecutionLock}
  )

{:ok, execution, state} = StatifierPersistence.Driver.create(driver, execution_id)

{:ok, execution, state} =
  StatifierPersistence.Driver.send_event(driver, execution_id, Statifier.Event.external("go"))
```

The two registrations are given once, to `new/3`: the driver carries them
inside `initialize:` on the create and stamps them on every step after it.

One call is one durable step, every effect through your `effects:`
executor, every `<invoke>` through your `dispatch:` fun inside that same
step, and then one further durable step per answer until the chart rests.
`{:ok, donedata}` answers `done.invoke.<id>`; `{:error, failure}` answers
`error.communication.invoke.<id>` with `Statifier.Session.failed_invocation/3`'s
own `reason`/`attempts`/`detail` payload, and means permanently failed
rather than "retry".

Both events are built field for field from the two doors
`Statifier.Session` gives a handler-backed invocation's host, `origin`
and `origintype` included, so the same chart sees the same event whether
it runs in a session or out of storage. That is asserted rather than
claimed: `test/statifier_persistence/driver_session_conformance_test.exs`
answers one document both ways and compares the `_event` each chart saw.

An answer whose invocation the chart has since cancelled is dropped, per
spec 6.4.3, and a chart whose answer re-arms its own call is bounded by
`max_turns:` rather than driven forever.

### Fanning one invocation out over N children

A durable subchart is one child per `<invoke>`, created inside the
parent's own step. An `<invoke>` that maps over a list is N of them, and N
creates cannot hold the parent's exclusion, so the children are started
afterwards - one call per child, from whatever job picks it up:

```elixir
StatifierPersistence.Driver.start_child_at(driver, parent_execution_id, effect, index, count,
  policy: :all
)
```

`effect` is the resolved `Statifier.Effect.Invoke` (or the whole
`{:start_child, resolved, {:invoke, invoke}}` instruction), `index` is the
child's 0-based position, and `count` is N. The call is idempotent on the
child's derived execution id, so a re-delivered start adopts the child it
already created instead of making a second one. Scheduling those calls is
a job runner's business, not this package's.

Each child then runs as an ordinary execution. When one reaches a terminal
status its answer is stored on its own execution record, and a settlement
section under the **parent's** exclusion asks - through an indexed status
projection, never a listing of whole records - whether all N have. Only
the settlement that finds them all terminal assembles the dense,
index-ordered list and answers the parent's ordinary door, once:

```elixir
[
  %{"index" => 0, "status" => "completed", "donedata" => %{"id" => "acct_1"}},
  %{"index" => 1, "status" => "failed", "failure" => %{"reason" => "declined", ...}},
  %{"index" => 2, "status" => "cancelled"}
]
```

`policy: :first_error` cancels the rest as soon as one child fails: the
started siblings through the cascading cancel, and the ones whose start
job has not run yet through the `child_canceller:` seam, which is handed
the parent execution id, the invocation id, and the indices with no
execution. Both
kinds read `"cancelled"` at their index in the same list.

A child fails on its own word, with no host in the loop, by settling in a
**failure-classed final** - a top-level `<final>` whose `<donedata>`
carries the reserved key `statifier_persistence:execution_status` set to
`"failed"`:

```xml
<final id="declined">
  <donedata>
    <param name="statifier_persistence:execution_status" expr="'failed'"/>
    <param name="reason" expr="decline_reason"/>
  </donedata>
</final>
```

That step is an ordinary successful one; the execution record takes `:failed`
with the `failure` string `"failed_final"`, and the whole `<donedata>` -
tag included, alongside whatever else the final carries - reaches the
parent's list verbatim. Macrostep-budget exhaustion is the other route to
`:failed`, and the `failure` string is what tells the two apart. An
unhandled `error.*` event is not a route: a chart that cannot continue
stays `:active` until its author routes the error to a final.
See `StatifierPersistence.Executions` for the full rule.

Before 0.12.0 that key was spelled `statifier_persistence:run_status`. Both
spellings are read for one release: in 0.12.0 the new key wins where both are
present and the old one logs a deprecation line, and 0.13.0 reads only
`statifier_persistence:execution_status` (ADR-0011 decision 4).

An adapter that cannot store a child's answer, or cannot answer the
status projection, is refused at open - a child whose invocation could
never be settled is not started. On the Ecto adapter both arrive with the
V03 migration.

## Status

Early, under active development, and the API is not frozen before 1.0.
The storage-adapter behaviour with its identity guard, the in-memory
reference adapter, the execution lifecycle and executor seam, per-execution
serialization, and the Ecto layer (configurable keys/tables, versioned
migrations, and the Postgres adapter below) all exist and are
conformance-tested.

## Documents, revisions, charts and executions

This package stores charts and executions. Documents and revisions are the
host's, and it has no table for either. The four words are written down here
so that the two sides line up, because nothing on these pages otherwise says
how a host gets from "the workflow an author edits" to "the chart an
execution runs".

Each word has exactly one job:

- A **document** is the stable thing a host names - the workflow an author
  opens and edits - under an id the host owns.
- A **revision** is one saved state of a document.
- A **chart** is what a revision compiles to, identified by its content
  hash. Documents and revisions never reach this package; the chart and
  the execution are what it stores.
- An **execution** runs exactly one chart for its whole life.

The join between the host's side and this package's side is a publish row
the **host** keeps:

    (document_id, revision, content_hash, published_at, status)

Three rules govern it:

- There is exactly one active publish per document.
- A new execution always starts on the document's active publish, and
  nothing that starts an execution names a content hash directly: the host
  reads the hash off the active publish.
- A republish mints a new chart and never touches a live execution. An
  execution drains on the chart it started on.

So the card-processing host above starts each new transaction through its
own publish row rather than through a hash it carries around:

```elixir
# MyApp.Catalog is the host's publish table, not this package's
%{content_hash: hash} = MyApp.Catalog.active_publish!("card-authorization")

{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, hash)
{:ok, machine} = Chart.from_binary(blob)
{:ok, execution, _state} = Executions.create(store, "txn_01J2", machine, opts)
```

## The Ecto adapter

Configure a persistence module on your own repo once, and migrate:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto, repo: MyApp.Repo
    end

    defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence)
    end

One migration covers every version of the package DDL on a fresh
database. If you already ran that migration when this package shipped
only V01, pick the later versions up with a second ordinary migration
rather than re-running the first:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistenceExecutionMetadata do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 2)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 2)
    end

`from:` says where a call starts and `version:` where it ends, in both
directions, so a migration's two calls always cover the same span: `up`
from `from:` (default V01) up to `version:` (default the newest), `down`
from `from:` (default the newest) back to `version:` (default V01). A
migration that caps one end caps the other to match - see "Upgrading to
V03 before deploying 0.7.0" below for the case that bites.

then build the guarded store the rest of the package works through:

    {:ok, store} =
      StatifierPersistence.Storage.new(
        StatifierPersistence.Storage.Ecto,
        persistence: MyApp.Persistence
      )

The adapter passes the same conformance suite the in-memory reference
does (`StatifierPersistence.Testing.StorageConformance` - point it at
your own adapter to hold it to the identical bar), stores engine
identities verbatim, and implements the optional per-execution
`lock_execution/3`
as a transaction-scoped advisory-plus-row lock (ADR-0004 as amended).
In your test suite, pass `sandbox: true` so each test runs in its own
`Ecto.Adapters.SQL.Sandbox` checkout via the adapter's `isolate/1`.

### Running on a backend that is not Postgres

The adapter is written against Postgres and this package's gate runs
against a real Postgres server, but only three of its callbacks are
actually Postgres SQL: `lock_execution/3` (advisory lock plus `FOR UPDATE`)
and the two metadata listings (`jsonb` containment). Everything else - charts,
positions, execution records, the identity guard, the executor seam, resume,
and the versioned migrations, V03's Postgres-only index included - runs
on any Ecto backend. So does the input log of V05: a table, four columns
and a unique index, with no `jsonb` predicate, no advisory lock and no
index type beyond a unique one, and the same conformance cases on both
backends.

A host on SQLite or another backend therefore **declines the lock
callback** rather than getting a portable imitation of it: pass your own
`serialization: {module, config}` strategy, backed by an exclusion the
host already owns (a job queue keyed per execution id, a single consumer) or
by a pass-through when the deployment is single-writer by construction. What
you must not do is leave the default in place, which reaches the
Postgres-only `lock_execution/3` and raises mid-execution.

The four conformance cases those three callbacks generate carry
`@tag :postgres`, so such a host runs the shipped suite green and honest:

    mix test --exclude postgres   #=> 31 tests, 0 failures, 4 excluded

[Running on a backend that is not Postgres](docs/non-postgres-backends.md)
is the full guide: what is Postgres-only and why, how to write the
strategy, what declining costs (durable subcharts and the execution listings
refuse rather than break), and how to verify your own setup.

### Upgrading to V03 before deploying 0.7.0

0.7.0 needs V03 of the package DDL, and the order matters: **run the
migration first, then deploy the new code.** `outcome_blob` is an
unconditional field on the generated execution schema, so 0.7.0 against a
V02 database fails on every query that touches the executions table, not
only on the fan-out write that introduced the column. The reverse order is
safe:
V03 on a database still served by 0.6.x adds a column nobody writes and
an index nobody's query needs yet.

From 0.12.0 an install that still owes V02, V03 or V04 - one capped below
version 4 - runs **V06 first, on its own**, and the versions it skipped
afterwards. For a host capped at V01:

    def up do
      StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 6, version: 6)
      StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 2, version: 5)
    end

    def down do
      StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, from: 5, version: 2)
      StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, from: 6, version: 6)
    end

Substitute your own cap in both spans - a host capped at V02 writes
`from: 3` on the second `up` and `version: 3` on the first `down`. V02, V03
and V04 alter the executions table, which on a database built before 0.12.0
carries that name only once V06 has renamed it (ADR-0011 decision 3). The
ordering rule is an *upgrade* rule only: V06's `down/1` is a no-op, so the
V06 call in the `down` above does nothing. V02-V05's arms name the
executions table under the name V06 gave it, and V01 - below the cap, in
your own earlier migration - is what drops it. An install already at V05
needs none of this: `from: 6` is the whole upgrade.

A host already on V02 picks V03 up with an ordinary migration of its own:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistenceOutcomeBlob do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 3)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 3)
    end

A host whose *first* migration is capped - `up(for: MyApp.Persistence,
version: 2)`, which is what keeps a fresh clone and an already-migrated
database on the same sequence of steps - caps its rollback the same way,
with `from: 2`:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
      use Ecto.Migration

      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, version: 2)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, from: 2)
    end

Leaving that `down` uncapped is the failure this ceiling exists to
prevent: Ecto rolls migrations back newest first, so `mix ecto.rollback
--all` runs the V03 migration's `down` and then this one's, which without
`from:` starts at V03 again and fails on a column that is already gone
(`no such column: outcome_blob`). Rolling back a single step is
unaffected either way.

V03 does two things, and only one of them is cheap.

**The `outcome_blob` column** is a nullable `:binary` added to the
executions table. Postgres adds a nullable column with no default as a
catalog-only change, so this part is fast whatever the table's size. It takes the
configured `:blob_type` with the other three blob columns, so a
`:blob_type` whose underlying database type is not binary needs the same
hand-written `ALTER` this README's encryption section already describes
for those three - now for four columns, not three.

**The `metadata` GIN index** is the part to plan for. V03's `up/1`
issues a plain `CREATE INDEX`, **not** `CREATE INDEX CONCURRENTLY`: it
takes a `SHARE` lock on the executions table for the whole build, which
blocks every `INSERT`, `UPDATE` and `DELETE` against that table until the
index is finished. Reads are unaffected. On a small or idle executions table
this is imperceptible. On a large one it is an outage of every write that
table takes - which, for a host stepping executions durably, means every
step of every execution.

How long that is depends on the row count, the width of the `metadata`
maps, and the server, so measure rather than guess. (`sp-461` is a
separate measurement issue and not a number for this build: it measures
the settlement read cost against a GIN-indexed `metadata` column at
increasing fan-out widths.)
The concurrent build is what a host with a large executions table wants, and
0.8.0 ships it as V04 - see below.

The index is not optional in effect: without it, every fan-out child
completion asks whether its N siblings are terminal with a `jsonb`
containment query, and each one is a sequential scan of the whole executions
table.

**On an Ecto adapter that is not Postgres, the index is skipped.** `GIN`
and `jsonb_path_ops` are Postgres spellings, so `up/1` creates the index
only when the migration's repo runs on `Ecto.Adapters.Postgres`, and
`down/1` drops it under the same condition. Everything else in V03 - the
`outcome_blob` column included - is created on every adapter, which is
what lets a SQLite host run this package's DDL at all. (In 0.7.0 it could
not: the index raised, the whole migration rolled back, and the column
went with it. Fixed in 0.7.1.)

What is skipped with the index is what the index served. Both metadata
queries this package issues -
`StatifierPersistence.Storage.Ecto.list_executions_by_metadata/2` and the
status projection `list_execution_states_by_metadata/2` - are `jsonb`
containment SQL, which a non-Postgres backend does not parse. So on such
an adapter the Ecto adapter declares no metadata support: a `metadata:`
map at create is refused with `{:error, :metadata_unsupported}`, the two
listings refuse with `{:error, :child_listing_unsupported}` and
`{:error, :execution_states_unsupported}` - and the two raw adapter callbacks
behind them answer `{:error, :metadata_unsupported}` rather than issuing
SQL the backend cannot parse, for a host that reaches them directly - and
a durable subchart or a fan-out
over that store is **refused at open** rather than started and left with
children nothing can settle. Storing, loading, stepping and resuming
executions are unaffected. Per-execution locking is a separate Postgres-only
surface - `lock_execution/3` is `pg_advisory_xact_lock` plus
`SELECT ... FOR UPDATE` -
and is tracked in `sp-5lm`.

### Building the metadata index concurrently: V04

0.8.0 adds V04, whose whole job is to rebuild V03's `metadata` GIN index
with `CREATE INDEX CONCURRENTLY` - same name, same expression, same
`jsonb_path_ops` opclass, built without the `SHARE` lock. It ships in the
same versioned helper as everything else, so a fresh database picks it up
with the one-call recipe and needs nothing else.

The one thing V04 cannot do for you is turn off the transaction it runs
in. `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block,
and Ecto reads `@disable_ddl_transaction` and `@disable_migration_lock`
from the module `Ecto.Migrator` runs - **your** migration, not a module
it delegates to. So V04 wants a migration of its own:

    defmodule MyApp.Repo.Migrations.RebuildStatifierPersistenceMetadataIndex do
      use Ecto.Migration

      @disable_ddl_transaction true
      @disable_migration_lock true

      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 4)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 4)
    end

Called from an ordinary transactional migration instead, V04 leaves V03's
index in place and does nothing else. That is deliberate rather than a
failure mode: the index it would have built is the one already there,
under the same name, and raising would break the one-call recipe every
fresh database and test harness uses, where a plain build on an empty
executions table costs nothing. It logs a warning when the executions table
already holds rows, which is the case where the plain build did block writes and
the two attributes are what you were missing.

`down/1` for V04 does nothing at all: what it leaves behind is V03's
index, and V03's `down/1` is what drops it. A non-transactional migration
has no rollback, so if the rebuild is interrupted, re-run the migration -
the drop is `drop_if_exists`, so it clears a missing or an invalid
leftover either way.

**A host with a large executions table that has not yet reached V03** is the
one case V04 does not solve by itself, because V03 still builds the index
plainly on the way past. Such a host adds the `outcome_blob` column by
hand, skipping V03's helper call entirely - after V06 has given the table
its current name:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistenceOutcomeBlob do
      use Ecto.Migration

      def up do
        alter table("executions") do
          add(:outcome_blob, :binary, null: true)
        end
      end
    end

substituting your configured table name and prefix, and then runs the V04
migration above for the index. That is a smaller hand-written migration
than 0.7.x asked for - the index half is V04's now - and the warning
about never calling `up(from: 3)` afterwards still applies: V03's
`create/1` is a plain `create`, not `create_if_not_exists`, so a second
run fails on the index that is already there.

**On an Ecto adapter that is not Postgres, V04 is a no-op**, both
directions, under the same adapter check V03 uses: there is no index to
rebuild, because V03 created none. Such a host needs neither attribute.

### Listing executions by host scope

An execution record carries engine identities and opaque blobs. Nothing on
it answers the question a multi-tenant host asks first - "list the
executions for scope X" - so ADR-0006 adds one optional, opaque `metadata`
map to an execution, stored beside it and handed back unchanged.

Take a card-processing host running a `myapp:authorize` / `myapp:capture`
chart, one execution per payment attempt, and a support screen that lists
every execution for one processor account. Tag the execution at create with
the account ids the host already keys its own tables by:

    {:ok, execution, _machine_state} =
      StatifierPersistence.Executions.create(store, payment_id, machine,
        executor: MyApp.Executor,
        metadata: %{
          "tenant_id" => "acct_01H8X",
          "processor_account_id" => "pacct_4471"
        }
      )

and read them back with an equality match on every pair:

    {:ok, executions} =
      StatifierPersistence.Storage.Ecto.list_executions_by_metadata(store.opts, %{
        "processor_account_id" => "pacct_4471"
      })

Equality on all given pairs is the whole query surface: no ranges, no
partial matches, no ordering guarantee. Anything richer is a query you
write against your own column - the table name is yours to configure, so
that is a supported thing to do. The V02 migration adds the column as
nullable `jsonb` with no index of its own, because which pairs you query
by is your call. V03 (above) adds the one containment index this
package's own settlement query needs, a GIN `jsonb_path_ops` index on the
whole column; an expression index on particular keys, or the wider
`jsonb_ops` operator set, is still yours to add when the volume asks.

Two rules come with it.

**Identities only, never personal data.** Keys and values are host
identities - a tenant id, a subject-entity id, a correlation id - and
never a name, an email address, a postal address, a card number, or any
other personal or cardholder data. This is a rule of the contract, not
advice: `:blob_type` encryption (below) covers the three blob columns and
does not reach this one, so anything you file here is at rest in the clear
no matter how the blobs are configured. The map is opaque to this package
by design, so nothing here can inspect a value and reject it - the rule is
kept by you.

**An adapter may refuse it.** An adapter that cannot store the map refuses
a non-empty one at the create with `{:error, :metadata_unsupported}`, so
you learn on the first call rather than finding a silently dropped scope
later. An empty or absent map is never refused. The shipped in-memory and
Ecto adapters both support it; a third-party adapter that does not is
still conformant, and the conformance suite tests both answers. The Ecto
adapter refuses at the same point for a value `jsonb` cannot hold - a
tuple, an atom, a pid, or a binary that is not valid UTF-8 - rather than
storing something that is not what you handed it. The map is write-once:
it is set at create and a later step or abandonment carries it forward
untouched.

An execution is the only thing this package scopes for you, and only through that
map. A chart is not: `StatifierPersistence.Storage.save_chart/3` keys a
chart on its content hash alone, so two tenants storing byte-identical
charts share one chart row. Tenant-qualify your own per-chart rows in your
own tables - folding a namespace into the hash would change what a chart's
identity is, which is statifier-ex's contract and not an option this
package offers.

### Recording an execution's inputs, so it can be replayed

A durably stepped execution stores a chart, a position and an execution
record, and none of them is an input. The position is the execution's
*current* configuration, overwritten on every step, so by construction the
history an offline replay needs is destroyed by the mechanism that makes the
execution durable.

ADR-0010 adds an optional per-execution input log to close that gap. It is
opt-in by export, exactly as the `metadata` map is: an adapter that
exports `supports_input_log?/1` and answers `true` keeps one, and an
adapter that does not stores no inputs and behaves exactly as it did
before. **Nothing refuses an execution over it** - a diagnostic facility must
not break the execution it is diagnosing - so ask before you rely on it:

    StatifierPersistence.Storage.input_log_supported?(store)

The Ecto adapter keeps the log on every backend, in the V05 table. Each
entry is the `%Statifier.Event{}` the interpreter was handed, verbatim,
stamped with the public door it entered by and a dense zero-based
ordinal:

    {:ok, entries} = StatifierPersistence.Executions.inputs(store, "exec_1")

    Enum.map(entries, &{&1.seq, &1.door, &1.event.name})
    #=> [{0, "step", "advance"}, {1, "answer_parent", "done.invoke.call"}]

One log belongs to one execution. A durable subchart's child is an ordinary
execution, so it has its own log; the parent's holds the answer it saw at
the `answer_parent` door, and not the child's inputs. Only inputs an
interpreter actually saw are recorded - a delivery to a terminal execution,
or to an invocation the chart has since cancelled, is discarded and appends
nothing, because a replay that applied it would produce a different
execution than the one that happened.

**Turning the log on is a data-retention decision, not a debugging
switch.** Chart, position and identity blobs are engine-shaped; an
event's `data` is your own values, and this is the first thing this
package stores that can hold personal or cardholder data. So `input_blob`
is a blob in the `:blob_type` sense below, and it is *not* the `metadata`
map, which stays in the clear by design. Bound how much accumulates with
a per-execution cap declared where every other adapter setting is:

    {:ok, store} =
      StatifierPersistence.Storage.new(
        StatifierPersistence.Storage.Ecto,
        persistence: MyApp.Persistence,
        input_log_cap: 500
      )

The default is `:infinity`; a bounded default would be this package
silently truncating your log. Past the cap the log **closes itself**: the
last slot is written as a marker entry whose `event` is `nil`, every
later append is refused, and the step itself succeeds and the execution
carries on. The marker is the point - a truncated log that looked complete
would satisfy every check a replay makes while replaying an execution that
never happened.

The replay itself is `statifier_ui`'s
(`StatifierUI.Trace.Replay.from_events/4`); ADR-0010 decision 8 names the
mapping from a stored entry to what that function takes, and nothing in
this package depends on `statifier_ui` to say so.

### Writing inside a caller's transaction

A host that keeps rows of its own beside an execution - an address row
that maps an incoming key to an execution id, say - can open one
transaction on its own repo and call `Executions.create/4` and
`Executions.step/5` inside it, from the same process. The two doors
then write through the caller's transaction rather than one of their
own. The `store` in the example is built over the caller's own repo:
its persistence module's `repo:` is `MyApp.Repo`, as in "The Ecto
adapter" above.

    MyApp.Repo.transaction(fn ->
      {:ok, _execution, _state} =
        StatifierPersistence.Executions.create(store, execution_id, machine, executor: MyApp.Executor)

      {:ok, _execution, _state} =
        StatifierPersistence.Executions.step(store, execution_id, machine, event, executor: MyApp.Executor)

      # ... the host's own writes ...
    end)

This works because `lock_execution/3` opens its transaction with
`repo.transaction/1`, and Ecto runs a transaction opened on the same repo
in the same process as part of the one already open. The contract,
pinned by `test/statifier_persistence/ecto/caller_transaction_test.exs`
against real Postgres:

- **Which doors.** `create/4` and `step/5`, called directly, over the
  Ecto adapter and the default serialization. A rollback leaves no
  execution row and no input log row behind; a commit keeps the
  execution and the input row `step/5` wrote, and later steps append
  after it as usual. The `StatifierPersistence.Driver` doors are not
  part of this contract: a child's drive answers its parent after its
  own exclusion is released (`Executions.cascade_cancel/3`'s doc says
  why that order matters), and inside a caller's transaction nothing is
  released before the commit. (Read from the code, not pinned by that
  test.)
- **Effects fire before the commit.** Both doors hand their effects to
  the executor before they write the execution record, and neither waits
  for the caller's transaction. A rollback does not un-fire an effect: whatever the
  executor did outside the repo has happened. Only writes the executor
  itself makes through the same repo, from the calling process, join the
  transaction and roll back with it (Ecto's ordinary rule, not this
  package's).
- **The lock joins the outer transaction.** The per-execution advisory
  lock and row lock are transaction-scoped, so inside a caller's
  transaction they are held until the caller commits or rolls back, not
  until the door returns. Another connection stepping the same execution
  waits for the caller's commit. A caller that touches two executions in
  one transaction holds both exclusions to the end, and the order it
  takes them in is the caller's to keep consistent. (Read from the
  code, not pinned by that test.)
- **An `:execution_exists` refusal aborts the caller's transaction.**
  `create/4` returns `{:error, :execution_exists}` for an id that
  already exists, but the refusal is a failed `INSERT` on the unique
  index, and Postgres refuses every later statement in that transaction.
  The caller's transaction ends in `{:error, :rollback}` and its other
  writes are rolled back. Treat the refusal as the end of the
  transaction: retry the lookup in a new one. The refused create has
  also already fired its initialize effects, exactly as it does outside
  a caller's transaction.

### Delivering while a step is in flight

A host that delivers events from more than one process - a webhook
controller with no partitioner in front of it, say - will sooner or later
call `Executions.step/5` for an execution while another `step/5` for the
same execution is still running. There is no separate door for that case,
because `step/5` already serializes it: every step runs its whole
fetch-to-persist tail inside the execution's serialization strategy, and
the default strategy is the adapter's own `lock_execution/3`. What a
second `step/5` does while the first holds that lock, per adapter:

| Storage | The second `step/5` while the first holds the lock |
|---|---|
| The Ecto adapter (Postgres) | Waits on the transaction-scoped advisory lock, then steps |
| `StatifierPersistence.Storage.InMemory` | Waits, retrying the lock every 5ms, then steps |
| An adapter that exports no `lock_execution/3` | Refused with `{:error, {:serialization, :not_supported}}` whether or not another step is in flight; nothing is fetched or written |
| Any adapter under a host's own `serialization:` strategy | Whatever that strategy does; this package waits on nothing of its own |

The first two rows are pinned by the test named below. The third is
pinned for `create/4` by `test/statifier_persistence/executions_test.exs`
and reaches `step/5` through the same default strategy; the fourth is
read from the code.

Pinned by `test/statifier_persistence/held_lease_test.exs`, on the Ecto
adapter against real Postgres and on the in-memory adapter's lock:

- **The second call waits, then steps.** It does not return while the
  first holds the lock, and it appends nothing to the input log until
  then. Once the first has persisted, the second reads the execution
  record and the position the first one wrote and steps from there, so
  both return `{:ok, execution, machine_state}` and the input log holds
  the first call's event before the second's.
- **A step the first one made terminal is discarded.** If the first
  step ends the execution, the second returns `{:discarded, execution}`
  once it gets the lock, and the log does not carry its event - the same
  answer any delivery to a terminal execution gets.

Read from the code, not pinned by that test:

- **No call is refused or discarded for being busy.** From `step/5`,
  `{:discarded, _}` means a terminal execution record, an event builder
  that declined, or a stored position that turned out to be terminal,
  never "the lock was held"; a held lock only ever makes a call wait.
- **Neither shipped adapter bounds the wait.** The in-memory adapter
  retries until the lock frees. The Ecto adapter passes no timeout of its
  own to the lock query, so what ends a long wait there is the repo's
  query timeout or a timeout the server enforces. A waiting call on the
  Ecto adapter holds a pooled connection for the whole wait, because its
  transaction is open before the lock query runs, so many deliveries
  waiting on one execution can use up the pool.
- **Order is the lock's.** A call that arrives while another holds the
  lock steps after it. Among several calls all waiting at once, the
  order they step in is the order the lock grants them - Postgres's lock
  queue on the Ecto adapter, whichever retry lands first on the in-memory
  one - and this package promises no more than that.
- **Inside a caller's transaction the lock is the caller's.** A `step/5`
  called inside a transaction the caller opened holds the lock until the
  caller commits or rolls back (the section above pins that for
  `create/4`, which takes the lock the same way), so a
  delivery from another process waits for the caller's commit, not for
  `step/5` to return.
- **The wait is visible.** `[:statifier_persistence, :execution, :lock]`
  reports the wait for the lock as its `duration`
  ([Telemetry](docs/telemetry.md)), which is where contention on one
  execution shows up.

### Encrypting the blob columns

`use StatifierPersistence.Ecto` hard-codes `:binary` for its payload blob
columns (`identity_blob`, `chart_blob`, `position_blob`, `outcome_blob`,
and the input log's `input_blob`) by default - plain `bytea`,
byte-identical round trip, nothing extra. Pass `:blob_type` to put a
custom Ecto type on those columns instead, and encryption at rest needs
no wrapping adapter:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        blob_type: MyApp.EncryptedBlob
    end

`:blob_type` accepts a bare module implementing `Ecto.Type`, or a
`{module, opts}` tuple for an `Ecto.ParameterizedType`. It reaches only
those payload columns: keys and lookup columns (`content_hash`,
`session_id`, `execution_id`, `status`, `failure`, and the input log's `seq`
and `door`) always stay plain, because the identity guard, the unique
indexes and the log's ordering depend on reading them back verbatim.

The shape a production `MyApp.EncryptedBlob` needs is a vault-backed or
envelope-encrypting `Ecto.Type` - `dump/1` encrypts on the way in,
`load/1` decrypts on the way out. This package takes no position on
which key-management scheme backs it; that choice belongs to the host.
To prove the shape without any encryption dependency, here is a minimal
`Ecto.Type` that reversibly transforms every byte (not encryption - a
stand-in to show the wiring):

    defmodule MyApp.ReversibleBlob do
      use Ecto.Type

      @mask 0xA5

      def type, do: :binary
      def cast(binary) when is_binary(binary), do: {:ok, binary}
      def cast(_other), do: :error
      def dump(binary) when is_binary(binary), do: {:ok, transform(binary)}
      def dump(_other), do: :error
      def load(binary) when is_binary(binary), do: {:ok, transform(binary)}
      def load(_other), do: :error

      defp transform(binary) do
        for <<byte <- binary>>, into: <<>>, do: <<Bitwise.bxor(byte, @mask)>>
      end
    end

The shipped migrations always emit `:binary` (`bytea`) for the payload
blob columns and do not read `:blob_type`. A `:blob_type` whose
underlying database type is still binary - an envelope-encrypting type
that dumps to and loads from raw bytes, like the sketch above - needs
no DDL change. A `:blob_type` that dumps to a different underlying type
(text, jsonb, a Postgres domain) needs you to alter those columns
yourself; the migrations helper does not do it for you.

### Placing a host column at a fixed position

Postgres appends any column an `ALTER TABLE` adds, so a host that wants
a column of its own at a fixed ordinal position on every table - a
tenant column at position 2, say - cannot get it by altering the tables
afterwards. Pass `:leading_columns` and the migrations helper puts the
columns there when it creates the tables:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        leading_columns: [tenant_id: {:text, null: true}]
    end

Each entry is `name: {type, opts}`, the arguments `Ecto.Migration.add/3`
takes. V01 and V05 emit the columns immediately after `id`, in the order
given, in every table they create - `charts`, `positions`, `executions`
and `inputs` - so `tenant_id` above sits at ordinal position 2 on all
four. No other version touches them.

The option only places the column:

- **It applies to a fresh create.** The columns exist only in tables V01
  and V05 create under the option. A table that already exists keeps the
  columns it has, and adding the option later changes nothing there -
  including on a database built before `0.12.0`, whose tables V06
  renamed in place rather than re-creating them.
- **Defaults and `NOT NULL` belong to a later migration of your own.**
  This package's inserts never name the column (below), so a `NOT NULL`
  without a default that holds for every insert fails every write the
  package makes. Declare the column nullable here, then give it its
  default and its `NOT NULL` in your next migration with
  `ALTER COLUMN ... SET DEFAULT` and `ALTER COLUMN ... SET NOT NULL`,
  which keep it where it is. Re-adding it with `ADD COLUMN` would move it
  to the end, and evaluate its default there and then to fill the
  existing rows - an expression such as `current_setting(...)` would
  have to resolve inside that migration.
- **The package never writes it.** The generated schemas do not
  declare the column, so every row this package inserts leaves it to the
  column's default - `NULL` until you set one. The one read is a prune
  you confine to a partition with `scope:` on
  `StatifierPersistence.Retention.prune/3` ([pruning one
  partition](docs/retention.md#pruning-one-partition)).

Two more options exist for a host that wrote these tables by hand and
wants the helper to build exactly what it wrote:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto,
        repo: MyApp.Repo,
        leading_columns: [tenant_id: {:text, null: true}],
        timestamps_position: :leading,
        column_collations: [execution_id: "C"]
    end

- **`timestamps_position: :leading`** puts `inserted_at` and
  `updated_at` immediately after the leading columns - after `id` when
  there are none - in every table V01 and V05 create, instead of last.
  The default, `:trailing`, is the layout this package has always
  built. A column a later version adds (`metadata`, `outcome_blob`,
  `retired_at`, `retired_by`, `ended_at`) lands at the end either way.
- **`column_collations: [name: collation]`** declares that package
  column with that collation wherever V01 or V05 creates it: above,
  `execution_id` is `COLLATE "C"` on both the executions and the inputs
  table. The names it takes are the text columns those two versions
  declare - `content_hash`, `session_id`, `execution_id`, `status`,
  `failure` and `door` - and the collation must be one your database
  knows. A column of your own takes its collation in its
  `:leading_columns` opts (`collation: "C"`, which `Ecto.Migration.add/3`
  already accepts).

Like `:leading_columns`, both apply to a fresh create only.

To replace a hand-written migration with the helper **at the same
migration version**, so that a database that already ran it runs
nothing again:

1. Configure the options above until the helper's tables match yours.
   Prove it on a scratch database: build one copy with your migration
   and one with the helper under a different `:table_prefix`, then
   compare `information_schema.columns` (name, type, collation,
   nullability, ordinal position) and `pg_indexes` table for table,
   with the prefix stripped. The diff must be empty. This package's own
   suite makes exactly that comparison against a hand-written mirror.
2. Replace the body of your migration with the helper calls covering
   the versions it stood in for, capped with `from:` and `version:` as
   "The Ecto adapter" above describes - a migration that stood in for
   V01 through V05 becomes `up(for: MyApp.Persistence, version: 5)`
   with `down(for: MyApp.Persistence, from: 5)`. Keep the file's name
   and version number.

`Ecto.Migrator` records that version as already run on every existing
database, so the new body only ever runs on a fresh one, where it
builds what the comparison proved identical.

## Pin sources

Some of what holds a chart in use is not in this package's tables: a
pending timer or an address row lives in a host's own store, and this
package depends on neither. A host teaches it about that state by
implementing `StatifierPersistence.PinSource`, whose single callback
answers named counts for one content hash, and by passing the source
modules in when it asks for a retirement. A source that cannot answer
raises rather than answering zero, and the refusal names the module. A
source that throws or exits - a call that times out inside it - is
refused the same way, with its own reason.

    defmodule MyApp.TimerPins do
      @behaviour StatifierPersistence.PinSource

      @impl true
      def pins(_content_hash, %{execution_ids: execution_ids}) do
        %{pending_timers: MyApp.Timers.count_scheduled_for(execution_ids)}
      end
    end

`context` carries `:execution_ids`, the ids of the `:active` executions
on that hash, so a source that knows executions and not hashes - a timer
queue over an advertising chart waiting for a click after an impression -
can answer without learning this package's key.

## Retiring a chart

A chart is stored once per content hash and stays for the life of the
store. When a host wants to stop carrying the bytes of a chart nothing
can resume, `StatifierPersistence.Executions.retire_chart/4` either
refuses with every count holding the chart or tombstones the row: it
keeps the row and its content hash, records `retired_at` and
`retired_by`, and nulls the two blob columns.

    case Executions.retire_chart(store, content_hash, [MyApp.TimerPins],
           retired_by: "ops@example.test") do
      {:ok, retired} ->
        {:retired, retired.retired_at}

      {:error, {:pinned, counts}} ->
        {:still_in_use, counts}

      {:error, {:pin_source_failed, {module, reason}}} ->
        {:ask_again_later, module, reason}
    end

Four things pin a chart and each refuses: an execution row on the hash
in the `:active` or the `:needs_migration` status, a durable child whose
linkage pin names the hash while its parent is in one of those two, a
position row on the hash, and any non-zero count from a pin source. A
`:needs_migration` execution is one a migration parked on its chart; it
takes no event until `Executions.unpark/3` puts it back to `:active` on
that chart, or a corrected plan through `Executions.migrate/4` moves it
onto the plan's `to` chart at `:active`, and `fail/4` and `cancel/3` end it as they
end an `:active` one. An
execution that has finished pins nothing - its counts are reported in
a refusal and never cause one - which is what keeps a chart retirable
once its traffic is over. Asking `Executions.executions_on/2` first
finds candidates; it is not a retirability test on its own, because it
reports the finished arms and leaves out the position rows and the
host's own sources.

A refusal carries every count it knows, so one answer says everything
holding the chart. A source that could not answer is a different arm
and carries no counts at all: the walk stopped, so no complete count
exists, and a partial one in the shape of a whole one is worse than
none.

Afterwards the hash is terminal on both chart doors: `fetch_chart/2`
answers `{:error, {:chart_retired, info}}` rather than
`:chart_not_found`, and `save_chart/3` refuses the same arm rather than
reviving the row. A host that retires a hash it still wanted
re-authors the document and saves the result under its new hash.

Retirement needs migration V07 and a store whose two chart blob columns
are nullable, which V07 can only arrange on Postgres. Elsewhere
`Storage.chart_retirement_supported?/1` answers `false` and the
retirement refuses at open with
`{:error, :chart_retirement_unsupported}`, naming the limit instead of
failing on a constraint. A host on another backend that wants the
capability alters those two columns in a migration of its own.

There is no clock here. Nothing retires on its own or on a schedule, no
call takes a duration, and when a chart should go is the host's policy.

## Pruning finished executions

A finished execution keeps its last position blob and, on an adapter that
keeps one, its whole input log. `StatifierPersistence.Retention.prune/3`
clears both for every execution that ended before a `DateTime` you pass,
in batches, and keeps the execution row: its status, answer and
`ended_at` stay, so the drained query still counts it and a parent can
still read a child's answer. As with retirement, the cutoff is your
policy and no call takes a duration.

[What a finished execution leaves behind](docs/retention.md) says what a
prune clears, which rows you may delete yourself and which you must not.

## Running the tests

The suite includes database-backed tests against a real Postgres server -
ADR-0005 rejects a skip tag for when one is absent, so `mix quality` and
`mix test` both need one reachable. Start it once with:

    docker compose up -d db

which brings up `postgres:17` on `localhost:5432` with user/password
`postgres`. Override host, port, user, password, or database name with the
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` env vars (see
`config/test.exs` for the defaults) if a server is already running
elsewhere.

## Surviving a restart

`docs/restart-demo.md` walks through the demo embedder that drives this
package's whole surface across a simulated restart with no Session
process: persist mid-execution with a pending durable timer and an in-flight
async invocation, drop everything volatile, cold-boot from the execution id
alone, and finish with zero duplicate side effects and a replay that
reproduces the path. The executable version lives in
`test/statifier_persistence/demo/restart_demo_test.exs` (and its
Postgres variant beside it).

## The contract this package builds on

The persisted-position story is already specified upstream, and this package
is one consumer of it rather than the definition of it:

- `docs/persistence.md` in statifier-ex covers what MachineState contains, the
  interned-index hazard, chart identity, and the resume recipe.
- ADR-0052 there records the rules: a persisted position is only meaningful
  against the exact chart revision that produced it, so every load is guarded
  by the Machine identity / content-hash. Loading a position against the wrong
  revision does not error - it silently resumes the wrong configuration.
- ADR-0060 records the resume API: the `:resume` option on
  `Session.start_link/2`, the pure-core rehydration path, and what a resume
  deliberately does not restore (in-flight delayed-send timers and live
  invoked children).

Read all three before adding code here.

## Scope

In scope:

- A storage-adapter behaviour: save/load of MachineState snapshots (or
  Recordings), guarded by the Machine identity so a position can never be
  loaded against the wrong chart revision.
- Execution lifecycle as a library: create/step/complete/fail, with a
  serialization guarantee per execution so concurrent event deliveries to one
  execution are ordered.
- The load -> handle_event -> execute effects -> persist loop, with effect
  execution delegated to the host.
- An Ecto adapter shipping schemas and migrations for chart definitions,
  versions, and executions; the host supplies the Repo and any tenancy columns.

Out of scope: domain actions, authoring UI, and job scheduling -
[statifier_oban](https://github.com/riddler/statifier_oban) owns timers and
async work.
