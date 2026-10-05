# What the chart lock reaches

Retiring a chart (`StatifierPersistence.Executions.retire_chart/4`) and
putting an execution on a chart race each other: a create or a migration
reads the chart's tombstone, finds none, and writes its execution, while
a retirement counts the chart's pins and writes the tombstone. On the
Ecto adapter over Postgres a per-chart advisory lock orders the two, so
one of them always sees the other. This page says what that lock makes
wait, what its key is, the one way your own code can deadlock on it, and
what it means for test suites running in parallel.

The design is ADR-0012's 2026-09-28 Amendment (the lock) and its
2026-09-29 Amendment (the key). The lock shipped in 0.23.0. The key this
page describes, scoped by the store, ships in the first release after
0.23.1; 0.23.0 and 0.23.1 key the lock on the content hash alone, as
"Before the store-scoped key" below describes.

## Where the lock is taken

Only `StatifierPersistence.Storage.Ecto`, and only when the repo's
adapter is Postgres, takes it. The in-memory adapter checks the tombstone
inside the same Agent transition that writes, and needs no lock. An Ecto
repo on another backend takes none, and the race is narrowed there, not
closed.

The lock is transaction-scoped (`pg_advisory_xact_lock` and
`pg_advisory_xact_lock_shared`). It is held until the transaction that
took it commits or rolls back, and a statement outside any transaction
releases it when the statement ends.

## The two modes

- **Shared**, taken by every tombstone read: `Storage.check_chart_retired/2`
  and the adapter's `fetch_retired_info/2`. `Executions.create/4`,
  `Executions.migrate/4` and `Executions.migrate_tree/4` each make that
  read inside the transaction they write in (for a tree, once per node's
  `to` chart), so under the default serialization strategy they hold the
  shared lock until the execution they put on the chart has committed.
- **Exclusive**, taken by a retirement: the adapter's `retire_chart/3`
  takes it as the first statement of its transaction, before it counts
  anything, and holds nothing on the chart before it.

A `serialization:` strategy of your own opens no database transaction
for the lock to live in, so a create under it, outside a transaction of
yours, holds the shared lock only for the read's own statement. The
race is narrowed there, not closed.

## What waits on what

For one chart in one store (the next section says what "one store" is):

| Already holding | Arriving | Waits? | What the arriving call then answers |
|---|---|---|---|
| a tombstone read (shared) | a tombstone read, from any create, migration or check | no | its own read; any number of writers on one chart proceed together |
| a tombstone read (shared) | a retirement (exclusive) | yes, until the reader's transaction ends | if the reader committed an execution on the chart, the retirement sees it and refuses with `{:error, {:pinned, counts}}`; otherwise it decides as it would have |
| a retirement (exclusive) | a tombstone read (shared) | yes, until the retirement's transaction ends | the read sees the tombstone, and the create or migration answers `{:error, {:chart_retired, info}}` having written nothing |
| a retirement (exclusive) | another retirement (exclusive) | yes | the retired arm if the first one tombstoned the chart, never a second tombstone |

Nothing waits across two different charts, or across two different
stores, short of a collision in the key's 32-bit hash, where two keys
behave as one. The per-execution lock the default
serialization strategy takes (`lock_execution/3`) is a different key
space and never meets this one.

Only the losing interleaving changes what a call answers. A create that
does not race a retirement answers what it always answered.

## The key, and why its unit is the store

The key is two `int4`s:

    (namespace, hashtext(store <> " " <> content_hash))

The namespace is a constant of the adapter (`@chart_lock_namespace`, the
bytes `SPCH`). The store is the table of your host module's chart schema,
under its Postgres schema prefix (the `:prefix` option, Ecto's
`@schema_prefix`) when it has one, each part written as a double-quoted
identifier: `"statifier_charts"` with the default table name and no
prefix, or `"loans"."statifier_charts"` with `prefix: "loans"`. The
`:table_prefix` option is part of the table name, so it is in the key
through the name.

So:

- **Two stores in one database do not wait on each other.** Two table
  names (from two `:table_prefix` values or two `:tables` overrides), or
  one table name under two schema prefixes, give one content hash two
  keys.
- **Two host modules on one physical table are one store.** Same table,
  same prefix: they share the key, because they share the rows the lock
  guards.
- **Tenants sharing one charts table share the lock.** The charts table's
  unique index is on `content_hash` alone. A tenant column you add with
  `:leading_columns` goes on the table, not into that index, so a chart
  has one row, and one tombstone, per store. A lock keyed per tenant
  would let a create for one tenant read the chart as not retired while
  a retirement for another tenant tombstoned that same row, which is the
  race the lock exists to close. The consequence is mild: creates never
  wait on each other (shared never waits on shared), and a retirement
  waits only for in-flight writes on the one chart it retires.

### The prefix-free edge

A chart schema with no schema prefix, which is the default, is keyed by
its table name alone. Which Postgres schema that name resolves to is the
connection's `search_path`, and the key does not include it. Two hosts
in one database with the same chart table name, no prefix, and
different `search_path` settings share a key though their rows are
apart. They wait on each other exactly as every store in one database
did before the store-scoped key; nothing answers differently. Give each
its own `:prefix` if the waits matter.

### Before the store-scoped key

On 0.23.0 and 0.23.1 the key is `(namespace, hashtext(content_hash))`:
database-wide. Every store in one database shares the lock of every
content hash they have in common, whatever tables or prefixes they use.

## Reading a chart, then retiring it, in one transaction of your own

This is the one way the lock can deadlock, and no call in this package
does it on its own: `Executions.retire_chart/4` reads no tombstone before
the adapter's `retire_chart/3` takes the exclusive lock as the first
statement of its transaction, and the creates, migrations and checks
take only the shared lock.

Your own transaction can. If it first reads a chart's tombstone, or
creates or migrates an execution onto that chart, and then retires the
same chart, it asks for the exclusive lock while it still holds the
shared one. One such transaction alone is granted the upgrade. Two at
once, on one chart in one store, each hold the shared lock and each wait
for the other to let it go, and Postgres ends one of them with
`deadlock_detected` (SQLSTATE `40P01`).

"Your own transaction" includes more than an explicit
`Repo.transaction/2`:

- an `Ecto.Multi`, or any function of yours that runs inside one;
- this package's calls made inside a transaction you opened, because
  they join it (README, "Writing inside a caller's transaction");
- **a test under the Ecto SQL sandbox**, where the whole test is one
  transaction, so a test that creates an execution on a chart and later
  retires that chart is such a caller.

To find one in your code, list the files that retire a chart and, in
each, every call that reads a tombstone or puts an execution on a chart:

    grep -rlE 'retire_chart' lib test \
      | xargs grep -nE 'retire_chart|check_chart_retired|fetch_retired_info|create\(|migrate\(|migrate_tree\('

For each file, ask whether a read and a retirement of the same chart can
run inside one transaction, and whether two such transactions can run at
once. If they can, any one of these removes the deadlock:

- retire in a transaction of its own, outside the one that read;
- retire first: a transaction that takes the exclusive lock before it
  reads holds nothing it has to upgrade;
- in tests, give each concurrently running test its own content hashes,
  or run those tests with `async: false`.

## Test suites in parallel

`StatifierPersistence.Testing.StorageConformance` gives every chart a
case retires a suffix derived from the using module's name. Two modules
running the suite at once against one database retire different content
hashes, so they never meet on one key, whatever their stores.

With the store-scoped key, two suites in one database meet on the lock,
for a hash they have in common, only when they also share a charts
table: two host modules on the same table and prefix. Suites on
different tables or prefixes never wait on each other's charts.

What neither covers is two operating-system processes running the same
module against the same database: two checkouts of one project, or
`mix test --partitions` with every partition pointed at one database.
The module name, and so the suffix, is the same in both, and so are the
table and the key. Give each process its own test database: the
database name in `config/test.exs` is where to do it. This package's
own suite does: its default test database name carries a suffix per
checkout and `MIX_TEST_PARTITION` when that is set, and `PGDATABASE`
overrides it.

## The router and the Oban adapter do not choose your version

`statifier_router` and `statifier_oban` depend on this package through a
version requirement (the Oban adapter's is optional). Each keeps its own
`mix.lock` for its own test suite, and that file never reaches your
application: the version of
`statifier_persistence` you run, and so which key the lock takes, is the
one your application's `mix.lock` resolved. To take the store-scoped key
once it is released, update `statifier_persistence` in your own project
(`mix deps.update statifier_persistence`) and check the version it
lands on in your `mix.lock`.
