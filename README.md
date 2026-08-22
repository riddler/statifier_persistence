# StatifierPersistence

Durable stepper and storage adapters for
[Statifier](https://github.com/riddler/statifier-ex).

Statifier's pure interpreter contract (machine_state, event -> machine_state,
effects) makes a persistence-first execution model possible: load a persisted
position, step it, execute the effects, persist. Hosts running charts that
span days or survive deploys should not need long-lived Session processes at
all - but every host currently hand-rolls the loop, the storage guard, and the
crash semantics. This package is that loop, packaged.

## Status

Pre-release, under active development. The storage-adapter behaviour with
its identity guard, the in-memory reference adapter, the run lifecycle,
and the Ecto layer (configurable keys/tables, versioned migrations, and
the Postgres adapter below) exist; nothing is published to Hex yet.

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
