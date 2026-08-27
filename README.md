# StatifierPersistence

[![CI](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_persistence/)
[![License](https://img.shields.io/hexpm/l/statifier_persistence.svg)](https://github.com/riddler/statifier_persistence/blob/main/LICENSE)

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
    {:statifier_persistence, "~> 0.1"},
    # Optional, for the Postgres adapter:
    {:ecto_sql, "~> 3.10"}
  ]
end
```

## A worked run

A card-processing transaction: authorize it, capture it before its
capture window closes, settle it. The whole run is four calls, and no
process holds the chart between them.

```elixir
alias Statifier.{Chart, Event, Machine, MachineState}
alias Statifier.Invoke.Types, as: InvokeTypes
alias StatifierPersistence.{Runs, Storage}

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
    # your own gateway call, keyed for idempotency by run and invocation
    MyApp.Payments.authorize(ctx.run_id, invoke.invoke_id)
    :ok

  _effect, _ctx ->
    :ok
end

opts = [executor: executor, invoke_types: InvokeTypes.new(types: ["myapp:authorize"])]
```

`create/4` initializes the chart, hands the resulting effects to the
executor, and persists the quiescent position under a run id you choose
- here the transaction's own key:

```elixir
{:ok, run, state} = Runs.create(store, "txn_01H8", machine, opts)
#=> run.status == :active, active leaf state "authorizing"
```

Each later event is one `step/5`: liveness check, guarded load, step,
effects out through the seam, persist. Between calls there is no live
process and no in-memory position - only the run record.

```elixir
{:ok, run, state} =
  Runs.step(
    store,
    "txn_01H8",
    machine,
    Event.external("done.invoke.authorize", invokeid: "authorize"),
    opts
  )

#=> run.status == :active, active leaf state "awaiting_capture"
```

### Across a restart

Nothing above kept state in the beam, so a deploy in the middle of the
run changes nothing about how it continues. Given only the run id, fetch
the record, fetch the chart bytes it names, and recompile:

```elixir
{:ok, record} = Storage.fetch_run(store, "txn_01H8")
{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, record.content_hash)
{:ok, rebooted} = Chart.from_binary(blob)
```

`rebooted` is compiled afresh from the stored bytes, not carried over
from before the restart, and it is what makes the stored position
readable again: Statifier interns state ids to indices at compile time,
so a position is only meaningful against the exact chart revision that
produced it. The identity guard enforces that on every load. Step a run
with a machine compiled from a *changed* chart and it refuses with
`{:error, {:identity_mismatch, stored, supplied}}` rather than silently
resuming the wrong configuration.

```elixir
{:ok, run, state} =
  Runs.step(store, "txn_01H8", rebooted, Event.external("capture.requested"), opts)

#=> run.status == :active, active leaf state "settling"

{:ok, run, state} = Runs.step(store, "txn_01H8", rebooted, Event.external("ack"), opts)
#=> run.status == :completed, no active leaf states
```

`:completed` is reached only by the chart reaching a final state - the
lifecycle consumes the interpreter's `:done` itself and never hands it
to your executor. `Runs.fail/4` is the one host-driven terminal
transition, and a step delivered to a terminal run comes back
`{:discarded, run}` rather than raising.

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
| `StatifierPersistence.Storage` | The identity-guarded facade: charts, positions, run records. Every load is guarded; there is no unguarded path |
| `StatifierPersistence.Storage.Adapter` | The behaviour a backing store implements. `Storage.InMemory` is the reference one, `Storage.Ecto` the Postgres one |
| `StatifierPersistence.Runs` | The lifecycle: `create/4`, `step/5`, `fail/4`, in ADR-0004's fixed order |
| `StatifierPersistence.Executor` | The seam every effect crosses on its way to your host |
| `StatifierPersistence.Serialization` | The per-run ordering strategy the fetch-to-persist tail runs inside; defaults to the adapter's own `lock_run/3` |
| `StatifierPersistence.Testing.StorageConformance` | The conformance suite - point it at your own adapter to hold it to the same bar |

Two things the loop deliberately does not do. Effect delivery is
at-least-once: a crash between step and persist re-drives the same event
and re-emits the same effects with identical deterministic keys, and the
loop never dedupes - idempotency on that key is yours. And a resumed run
restores position, not liveness: pending timers and in-flight
invocations are re-established by the host, from its own durable rows.
[Surviving a restart](docs/restart-demo.md) walks a demo embedder
through both.

## Status

Early, under active development, and the API is not frozen before 1.0.
The storage-adapter behaviour with its identity guard, the in-memory
reference adapter, the run lifecycle and executor seam, per-run
serialization, and the Ecto layer (configurable keys/tables, versioned
migrations, and the Postgres adapter below) all exist and are
conformance-tested.

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

then build the guarded store the rest of the package works through:

    {:ok, store} =
      StatifierPersistence.Storage.new(
        StatifierPersistence.Storage.Ecto,
        persistence: MyApp.Persistence
      )

The adapter passes the same conformance suite the in-memory reference
does (`StatifierPersistence.Testing.StorageConformance` - point it at
your own adapter to hold it to the identical bar), stores engine
identities verbatim, and implements the optional per-run `lock_run/3`
as a transaction-scoped advisory-plus-row lock (ADR-0004 as amended).
In your test suite, pass `sandbox: true` so each test runs in its own
`Ecto.Adapters.SQL.Sandbox` checkout via the adapter's `isolate/1`.

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
process: persist mid-run with a pending durable timer and an in-flight
async invocation, drop everything volatile, cold-boot from the run id
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
- Run lifecycle as a library: create/step/complete/fail, with a serialization
  guarantee per run so concurrent event deliveries to one run are ordered.
- The load -> handle_event -> execute effects -> persist loop, with effect
  execution delegated to the host.
- An Ecto adapter shipping schemas and migrations for chart definitions,
  versions, and runs; the host supplies the Repo and any tenancy columns.

Out of scope: domain actions, authoring UI, and job scheduling -
[statifier_oban](https://github.com/riddler/statifier_oban) owns timers and
async work.
