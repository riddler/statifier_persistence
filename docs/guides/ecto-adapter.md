# How to set up the Ecto adapter

This guide shows you how to put the Postgres-backed storage adapter under
your own Ecto repo: configure a persistence module, migrate, and build the
guarded store the rest of the package works through. The store it builds is
the one [How to persist an execution and resume it in another
process](persist-and-resume.md) uses with the in-memory adapter, so a host
that has followed that guide swaps one `new/2` call.

## Before you start

You need `ecto_sql` in your dependencies (it is optional for this package,
see the README's Installation section) and an Ecto repo, called `MyApp.Repo`
below. A database that an older release of this package already migrated,
before 0.13, needs the steps in [Upgrading a host from 0.13 to
0.25.0](../upgrading.md) first.

## Configure a persistence module

Define a module that says which repo holds the tables:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto, repo: MyApp.Repo
    end

## Migrate

Add one migration that calls the versioned helper:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence)
    end

One migration covers every version of the package DDL on a fresh database.

### Pick up later versions on a database you already migrated

If you already ran that migration when this package shipped only V01, pick
the later versions up with a second ordinary migration rather than
re-running the first:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistenceExecutionMetadata do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 2)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 2)
    end

`from:` says where a call starts and `version:` where it ends, in both
directions, so a migration's two calls always cover the same span: `up`
from `from:` (default V01) up to `version:` (default the newest), `down`
from `from:` (default the newest) back to `version:` (default V01). A
migration that caps one end caps the other to match - [Upgrading a host from
0.13 to 0.25.0](../upgrading.md) shows
the case that bites.

## Build the guarded store

Hand the persistence module to `StatifierPersistence.Storage.new/2`:

    {:ok, store} =
      StatifierPersistence.Storage.new(
        StatifierPersistence.Storage.Ecto,
        persistence: MyApp.Persistence
      )

The adapter passes the same conformance suite the in-memory reference does
(`StatifierPersistence.Testing.StorageConformance` - point it at your own
adapter to hold it to the identical bar), stores engine identities
verbatim, and implements the optional per-execution `lock_execution/3` as a
transaction-scoped advisory-plus-row lock (ADR-0004 as amended).

## Isolate each test

In your test suite, pass `sandbox: true` so each test runs in its own
`Ecto.Adapters.SQL.Sandbox` checkout via the adapter's `isolate/1`.

## Run on a backend that is not Postgres

The adapter is written against Postgres, and only three of its callbacks are
Postgres SQL: `lock_execution/3` and the two metadata listings. A host on
SQLite or another backend declines the lock callback by passing its own
`serialization: {module, config}` strategy, and must not leave the default
in place, which reaches the Postgres-only `lock_execution/3` and raises
mid-execution. Run the shipped suite with `mix test --exclude postgres` to
skip the five conformance cases those callbacks generate.

[How to run the Ecto adapter on a backend that is not
Postgres](../non-postgres-backends.md) is the full guide: what is
Postgres-only and why, how to write the strategy, what declining costs, and
how to verify your own setup.
