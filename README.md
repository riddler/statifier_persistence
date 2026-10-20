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
> [`docs/upgrading.md`](docs/upgrading.md).

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
    {:statifier_persistence, "~> 0.25.0"},
    # Optional, for the Postgres adapter:
    {:ecto_sql, "~> 3.10"}
  ]
end
```

## Documentation

- Do
  - [How to set up the Ecto adapter](docs/guides/ecto-adapter.md) - configure a persistence module, migrate, build the guarded store, and run on a backend that is not Postgres
  - [How to persist an execution and resume it in another process](docs/guides/persist-and-resume.md) - store an execution after every step and carry it on from another process with only its id
  - [How to drive a chart that calls out](docs/guides/drive-a-chart.md) - run an execution whose chart invokes your host, and fan one invocation out over N children
  - [How to list executions by host scope and record inputs for replay](docs/guides/host-scope-and-inputs.md) - tag an execution with your own scope ids and list by them, and keep an input log so an execution can be replayed
  - [How to step inside a caller's transaction](docs/guides/caller-transaction.md) - write your own rows in the same transaction as a step, commit timer rows with the step's position, and deliver events while a step is in flight
  - [How to encrypt the blob columns and place host columns](docs/guides/encrypt-and-place-columns.md) - put an encrypting Ecto type on the payload columns, and put a column of your own at a fixed position in every table the migrations helper creates
  - [How to retire a chart and prune finished executions](docs/guides/retire-and-prune.md) - teach a retirement about state outside this package, retire a chart nothing can resume, and prune the position blobs and input logs of executions that have ended
  - [How to move executions onto a newer chart](docs/guides/move-executions.md) - move one execution, a parent with its durable children, or every execution on a chart onto the chart from a document's next revision, and park one the plan refuses
- Understand
  - [Documents, revisions, charts and executions, and why an execution is a durable row](docs/explanation/documents-revisions-charts-executions.md) - what the host keeps, what this package stores, and why an execution is a row that outlives every process

## Status

Early, under active development, and the API is not frozen before 1.0.
The storage-adapter behaviour with its identity guard, the in-memory
reference adapter, the execution lifecycle and executor seam, per-execution
serialization, and the Ecto layer (configurable keys/tables, versioned
migrations, and the Postgres adapter) all exist and are
conformance-tested.

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

## Scope

In scope:

- A storage-adapter behaviour: save/load of MachineState snapshots (or
  Recordings), guarded by the Machine identity so a position can never be
  loaded against the wrong chart.
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
