# Upgrading a host from 0.13 to 0.25.0

This page says what a host changes to move `statifier_persistence` from
0.13.0 to 0.25.0, one minor at a time. A host here is the code that
embeds the package: the module that calls `use StatifierPersistence.Ecto`,
the migrations it runs, the options it passes to
`StatifierPersistence.Executions` and `StatifierPersistence.Driver`, the
telemetry handlers it attaches, and any storage adapter of its own. What
each release added is in [CHANGELOG.md](../CHANGELOG.md); this page lists
only what a host has to do about it, and says **NONE** where the answer is
nothing.

Take the minors in order, and move the pin with each one, as the README
recommends: `{:statifier_persistence, "~> 0.14.0"}`, then `"~> 0.15.0"`,
then `"~> 0.16.0"`, then `"~> 0.17.0"`, then `"~> 0.18.0"`, then
`"~> 0.19.0"`, then `"~> 0.20.0"`, then `"~> 0.21.0"`, then `"~> 0.22.0"`,
then `"~> 0.23.0"`, then `"~> 0.24.0"`, then `"~> 0.25.0"`.
The `statifier` floor stays `~> 2.6` through 0.17.0; 0.18.0 moves it to
`~> 2.9`, and every later release through 0.24.2 keeps it there; 0.25.0
moves it to `~> 2.15`.

## Before you start: the database is at V07

0.13.0 needs migration V07, so a host running 0.13.0 has already run it.
If yours has not, run it before anything below: an install at V06 takes it
with its own migration,

    defmodule MyApp.Repo.Migrations.AddStatifierPersistenceRetirement do
      use Ecto.Migration

      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 7)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 7)
    end

and an install still short of V06 follows the V06 ordering rule in the
`StatifierPersistence.Ecto.Migrations` documentation first (a host older
than 0.13 that has not reached V03 or V04 reads the section on them below).
No release before 0.17.0 adds a migration; 0.17.0 does (V08, under
"0.16 to 0.17"), and no release from 0.18.0 through 0.25.0 adds one, and neither do the
0.23.1, 0.24.1 and 0.24.2 patches.

## If the database is older than V07: V03 and V04

A host that last migrated before 0.13 may not have reached V03 or V04, the
versions that add the `outcome_blob` column and the `metadata` index. Read
this section before the V07 step above if yours is one of them; a host that
is already at V05 or later skips it.

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
configured `:blob_type` with the three blob columns V01 created
(`identity_blob`, `chart_blob` and `position_blob`), so a `:blob_type` whose
underlying database type is not binary needs the same hand-written `ALTER`
[How to encrypt the blob columns and place host columns](guides/encrypt-and-place-columns.md#check-the-columns-database-type) describes for those
three - now for `outcome_blob` as well.

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

## 0.13 to 0.14

Schema: **NONE**. `:needs_migration`, the new fifth execution status, is a
new string in the existing status column, which has no constraint.

- **Move every node to 0.14 before any execution is parked.** A node still
  on 0.13 does not read `:needs_migration`. Only
  `StatifierPersistence.Executions.migrate/4` under `on_failure: :park`
  parks an execution, so a host that never calls it with `:park` never
  writes the status.
- **If you pass `routes:`, `invoke_types:` or `send_types:` to
  `create/4` beside `executor:`**, move them inside `initialize:`. They
  were ignored there, and a top-level `send_types:` left the execution
  without your registered send types for its whole life. Dialyzer now
  reports them, because `create/4` and `step/5` each name their own option
  type. It also reports `entry:`, `invoke_id:` or `child_count:` on
  `create/4`, which are the package's own telemetry options, and
  `initialize:`, `metadata:` or `linkage:` on `step/5`, which did nothing
  there; drop them.
- **If you match an execution's status exhaustively**, add a clause for
  `:needs_migration`, or a catch-all.
- **If you match the answer of `StatifierPersistence.Executions.executions_on/2`
  or `StatifierPersistence.Storage.count_executions_by_content_hash/2` as a
  closed map**, accept a sixth key, `needs_migration`; a `{:pinned, counts}`
  refusal carries it under `executions`.
- **If you handle `[:statifier_persistence, :adapter, :call]` and match its
  `callback` exhaustively**, add `:supports_retired_info?` and
  `:fetch_retired_info`: a create's retired-chart check reports those two
  in place of `:fetch_chart` on both bundled adapters. A handler that
  raises on them is detached by `:telemetry`.
- **If you match `t:StatifierPersistence.PinSource.reason/0`
  exhaustively**, add `{:thrown, value}` and `{:exited, reason}`: a pin
  source that throws or exits is now refused instead of escaping the call.
- **If you will park executions**, handle the migration arm: an event
  delivered through `step/5` or a `StatifierPersistence.Driver` door to a
  parked execution answers `{:error, {:needs_migration, execution}}` and
  writes nothing. Redelivering after the execution leaves the arm - a
  corrected `migrate/4`, or `StatifierPersistence.Executions.unpark/3` - is
  yours.
- **If you will migrate executions onto a newer chart**, pass the pin
  source that knows your pending timers as `pin_sources:` on `migrate/4`,
  beside `from_machine:` and `to_machine:`. A plan that leaves unmapped or
  drops a state that could own a timer is refused with
  `{:error, {:no_pin_source, states}}` without one. It is the same
  `StatifierPersistence.PinSource` module you pass to `retire_chart/4`;
  a host whose timers are `statifier_oban` jobs can adopt
  `StatifierOban.Timer.PinSource` for it. A host that never migrates:
  **NONE**.
- **If you ship a storage adapter of your own**: store and read back
  `:needs_migration`, count it under its own key in
  `count_executions_by_content_hash/2`, count a durable child's pin while
  its parent is `:active` or `:needs_migration`, and refuse to retire a
  chart a `:needs_migration` execution is on, or one a durable child's pin
  names while that child's parent is `:needs_migration`.
  `StatifierPersistence.Testing.StorageConformance` checks each. The
  two new callbacks `supports_retired_info?/1` and `fetch_retired_info/2`
  are optional.
- `leading_columns:` on `use StatifierPersistence.Ecto` is **NONE** for an
  existing install: it places host columns only in tables V01 and V05
  create. A host that wants a column of its own at a fixed position sets it
  before its tables exist; see [How to encrypt the blob columns and place host columns](guides/encrypt-and-place-columns.md#place-a-host-column-at-a-fixed-position).

## 0.14 to 0.15

### 0.15.0

Schema: **NONE**.

- **If you call `migrate/4`**, check your plans against three new
  refusals, each a finding inside `{:migration_refused, findings}` (or a
  park under `on_failure: :park`): `{:invocation_outside_configuration, _, _}`
  for a live invocation kept or moved onto a state the migrated execution
  is not in, `{:illegal_configuration, state_ids}` for a configuration the
  to chart cannot hold, and `{:invocation_element_changed, _, _}` for a
  live invocation kept or moved onto another `<invoke>` element. Give an
  unnamed `<invoke>` an `id` before you edit the state that holds it, and
  add a clause for each finding, or a catch-all, to every `case` over
  `t:StatifierPersistence.Executions.migration_finding/0`.
- `StatifierPersistence.Executions.migrate_tree/4`, which moves a parent
  and its durable children together, is new and optional: **NONE** unless
  you adopt it. On a storage adapter of your own it answers
  `{:error, :tree_migration_unsupported}` until you implement the two
  optional callbacks `supports_tree_migration?/1` and
  `write_tree_migration/2`.
- `[:statifier_persistence, :child, :answered]` gains a `delivery` key.
  **NONE** is required; a handler that should notice a durable child's
  answer a parked parent refused reads it.

### 0.15.1

Schema: **NONE**, and no error shape a host matches is added or removed.

- **If you attach handlers to `StatifierPersistence.Telemetry.events/0` and
  match the event name exhaustively**, add clauses for
  `[:statifier_persistence, :execution, :step, :exception]` and
  `[:statifier_persistence, :execution, :unparked]`.
- **If you pair step spans**, close a span on `:exception` as well as on
  `:stop`: a drive that raises, throws or exits - your executor or event
  builder included - now closes its span with `:exception` in place of
  `:stop`.
- **If you call `migrate/4` or `migrate_tree/4`**, a stored active
  invocation whose ordinal names no `<invoke>` element of its state is now
  refused with `{:invocation_element_changed, key, target}` when the plan
  keeps it at that ordinal. Repair the stored position.

## 0.15 to 0.16

Schema: **NONE**.

- **If your handler on `[:statifier_persistence, :child, :answered]`
  matches `delivery` exhaustively**, add `:parent_unfetched` and
  `:parent_chart_unresolved`, or a catch-all. On those two values
  `outcome` is the child's own and `failed_count` is `nil`, even for a
  fan-out.
- `timestamps_position:` and `column_collations:` on
  `use StatifierPersistence.Ecto` are **NONE** for an existing install:
  like `leading_columns:`, they apply only to tables V01 and V05 create,
  and their defaults are the layout earlier releases create.

## 0.16 to 0.17

0.17.0 adds `ended_at`, the time an execution ended, and
migration V08, which adds the column and an index on it.

- **Run V08 before you deploy the new version.** The execution schema the
  new version generates reads `ended_at` on every query, so an executions
  table without the column fails every read. Migrate first, then deploy:

      defmodule MyApp.Repo.Migrations.AddStatifierPersistenceEndedAt do
        use Ecto.Migration

        def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 8)
        def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 8)
      end

  V08 runs inside an ordinary transaction, on every backend. Nodes still
  on 0.16 keep working while the column exists: the 0.16 schema does not
  declare it. Rolling V08 back drops the column and every stamp in it.
- **Expect `nil` on executions that ended before V08.** V08 backfills
  nothing: a row already terminal reads `ended_at` as `nil` until a later
  terminal write reaches it, and that write stamps its own time.
  `StatifierPersistence.Executions.ended?/1` answers whether an execution
  carries the stamp.
- **If your schema is hand-written DDL**, add a nullable
  `utc_datetime_usec` `ended_at` column to the executions table and an
  index on it; `StatifierPersistence.Ecto.Migrations.expected_version/0`
  answers 8.
- **If you ship a storage adapter of your own**, store `ended_at` from
  `t:StatifierPersistence.Storage.Adapter.execution_record/0`, and in
  `update_execution/2` keep a stored stamp over the one a later record
  carries. `StatifierPersistence.Testing.StorageConformance` checks both.
- `leading_columns:` and `timestamps_position:` do not move `ended_at`:
  V08 alters an existing table, so the column lands at the end.
- `StatifierPersistence.Retention.prune/3` is new in 0.17.0: it clears
  the position blob and the input log of every execution that ended before
  a cutoff you pass, and keeps the execution row. Nothing calls it for
  you, so **NONE** is required; `docs/retention.md` says which rows you may
  delete for a finished execution.
- The two storage adapter callbacks that back it, `supports_execution_pruning?/1`
  and `prune_executions/3`, are optional, and **NONE** is required of an
  adapter of your own: one that exports neither stays conformant, and
  `StatifierPersistence.Retention.prune/3` answers
  `{:error, :execution_pruning_unsupported}` on it. The in-memory and Ecto
  adapters implement both. `prune_executions` takes a fourth argument from
  0.19.0; see "0.18 to 0.19" below.

## 0.17 to 0.18

Schema: **NONE**. 0.18.0 requires `statifier ~> 2.9`.

- **Let `statifier` resolve to 2.9.** 0.18.0 reads
  `Statifier.MachineState`'s `last_selection`, which statifier 2.9.0
  adds. A host that pins `statifier` itself below 2.9 lifts that pin, then
  updates both packages together.
- **If you call `StatifierPersistence.Executions.migrate/4` on a durable
  child**, expect `{:error, {:linked, execution}}`: `migrate/4` now
  refuses an execution that carries a linkage and writes nothing, under
  either `on_failure:` value, so a `:park` call parks nothing. Move a
  child with `StatifierPersistence.Executions.migrate_tree/4`, the child
  as the root, which moves its row and its linkage pin together. If you
  match `t:StatifierPersistence.Executions.migrate_error/0` exhaustively,
  add a clause for `{:linked, execution}`, or a catch-all.
- **If you fetch a completed child's record and match `donedata: nil`**,
  expect its donedata instead. `StatifierPersistence.Execution.from_record/1`
  reads a recorded `{:done, donedata}` answer back as `donedata`, so a
  fetched completed child of a durable subchart, a fan-out child's
  included, carries the donedata it answered its parent with. Every other
  record still reads `donedata: nil`.
- **If you deliver a refused answer again**, you can take it from the
  child's record: a single child now records its answer on its own
  execution record before its parent's door is tried, on an adapter that
  stores answers (`StatifierPersistence.Storage.execution_outcome_supported?/1`).
  Fetch the child and answer through
  `StatifierPersistence.Driver.answer_parent/3` with
  `{:done, execution.donedata}`, or `{:failed, reason: execution.failure}`
  for a failed child. A single child that ended before 0.18.0 has no
  recorded answer; delivering its answer again still needs the answer you
  held. A host that never redelivers: **NONE**.
- **If you attach handlers to `StatifierPersistence.Telemetry.events/0` and
  match the event name exhaustively**, add a clause for
  `[:statifier_persistence, :execution, :step, :reentered]`. It fires
  inside the step span, once per `error.communication` event the persist
  tail re-entered after an executor failure, carrying `name`, `origin`
  and `opts`. A host that folds the events it delivered to rebuild a
  position folds each one after the event of the step that produced it,
  through `Statifier.Interpreter.deliver_internal(machine_state,
  :platform, name, origin, opts)`; a host that does not: **NONE**.
- `[:statifier_persistence, :execution, :step, :stop]` gains a
  `selection` key: `:selected` or `:none` when the event the step
  delivered ran an external round, whether or not tracing is on, and
  `nil` on a stop that delivered no event or returned no position.
  **NONE** is required; a handler that matches the stop's metadata as a
  closed map accepts the new key.

## 0.18 to 0.19

Schema: **NONE**. The `statifier` floor stays `~> 2.9`.

- **If you wrote a storage adapter of your own that prunes**, move its
  optional `prune_executions/3` to
  `c:StatifierPersistence.Storage.Adapter.prune_executions/4`. The fourth
  argument is the scope, `[]` when the host gave none, and an adapter
  still exporting only `prune_executions/3` is no longer counted as
  declaring pruning: `StatifierPersistence.Retention.prune/3` answers
  `{:error, :execution_pruning_unsupported}` for it. With `[]`, select
  the batch as before. An adapter that can confine a batch to the scope's
  column equalities carries them on every statement the batch runs; one
  that cannot answers `{:error, :unscoped_adapter}` for any scope that is
  not `[]` and clears nothing. A host whose adapters are the two this
  package ships: **NONE**.
- **If you match `t:StatifierPersistence.Storage.Adapter.error/0`
  exhaustively**, add a clause for `:unscoped_adapter`, or a catch-all.
  It is the refusal of a scope from an adapter that cannot confine a
  batch to one partition; the in-memory adapter answers it for any
  `scope:`.
- `StatifierPersistence.Retention.prune/3` gains a `scope:` option that
  confines a prune to the rows holding its column equalities, over
  columns you placed with `:leading_columns` ("Pruning one partition" in
  [`docs/retention.md`](retention.md#pruning-one-partition)). Left out,
  the prune covers the whole store as before: **NONE** is required.

## 0.19 to 0.20

Schema: **NONE**. The `statifier` floor stays `~> 2.9`.

- **If you attach handlers to `StatifierPersistence.Telemetry.events/0` and
  match the event name exhaustively**, add clauses for the three events
  of the span `StatifierPersistence.Executions.migrate_batch/3` opens:
  `[:statifier_persistence, :execution, :migrate_batch, :start]`,
  `[..., :stop]` and `[..., :exception]`, or a catch-all.
- **If your handler on `[:statifier_persistence, :adapter, :call]` matches
  `callback` exhaustively**, add `:list_execution_ids_by_content_hash`, or
  a catch-all.
- **If you wrote a storage adapter of your own**, you may implement the
  new optional callback
  `c:StatifierPersistence.Storage.Adapter.list_execution_ids_by_content_hash/3`
  under the
  `c:StatifierPersistence.Storage.Adapter.supports_content_hash_query?/1`
  capability. An adapter that leaves it out keeps working;
  `migrate_batch/3` against it, and
  `StatifierPersistence.Storage.list_execution_ids_by_content_hash/3`,
  answer `{:error, :content_hash_query_unsupported}`. A host whose
  adapters are the two this package ships: **NONE**.

## 0.20 to 0.21

Schema: **NONE**. The `statifier` floor stays `~> 2.9`.

- **If an executor calls back into the execution it is stepping**, expect
  `{:error, {:reentrant_step, execution_id}}` from that call. Every public
  door of `StatifierPersistence.Executions` that takes an execution id
  (`create/4`, `step/5`, `fail/4`, `cancel/3`, `unpark/3`, `migrate/4`,
  `migrate_tree/4`, `inputs/2`) now refuses an execution whose executor is
  running in the calling process, before it reads or writes anything.
  Before, the nested call's write was overwritten by the outer step with
  nothing reported. A door for another execution is served as before, and
  a host that never calls back into the execution it is stepping:
  **NONE**.
- **If you match `t:StatifierPersistence.Executions.error/0`
  exhaustively**, add a clause for `{:reentrant_step, execution_id}`, or a
  catch-all.
- `StatifierPersistence.Retention.prune/3` gains `single_batch: true`,
  which prunes one batch and answers that batch's counts plus `more?`, so
  a host can hold one short transaction of its own per batch. Left out,
  the prune drains every batch as before: **NONE** is required.
- **If you run `StatifierPersistence.Testing.StorageConformance` against a
  storage adapter of your own**, your suite now runs one more case, "a
  door called from inside its own execution's executor refuses, and the
  outer step is stored". It needs no `lock_execution/3` and carries no
  tag, so it runs by default.

## 0.21 to 0.22

Schema: **NONE**. The `statifier` floor stays `~> 2.9`.

- **If an event builder handed to `StatifierPersistence.Executions.step/5`
  calls back into the execution it was handed**, expect
  `{:error, {:reentrant_step, execution_id}}` from that call, as an
  executor gets since 0.21.0. Before, the nested write was overwritten by
  the outer step with nothing reported. A builder that never calls back
  into its own execution: **NONE**.
- **If you run a dry run of `StatifierPersistence.Executions.migrate_batch/3`
  from inside an executor or an event builder**, the execution being
  stepped now answers `{:would_refuse, {:reentrant_step, execution_id}}`,
  before it is read, as the apply refuses it through `migrate/4`. The
  other executions the batch lists are previewed as before; a dry run
  called from anywhere else: **NONE**.
- **If you migrate executions whose chart schedules timers**, expect
  `migrate/4`, `migrate_tree/4` and `migrate_batch/3` to refuse a plan
  that keeps a state whose delayed `<send>` to the execution itself names,
  as a literal event, one the from chart listens for and the to chart no
  longer does. The refusal is `{:migration_refused, findings}` carrying
  `{:timer_event_removed, state_id, event}` (a park under
  `on_failure: :park`, and `{:would_refuse, {:migration_refused,
  findings}}` in a batch dry run). The check is static over the two
  charts, so it refuses whether or not a timer is pending. Before, the
  migration succeeded and a timer that state had scheduled fired later
  into a chart that ignored its event. Handle the event in the to chart,
  or drop the state. A plan that drops it is then checked against the pin
  sources you pass (ADR-0013 decision 6): with none it answers
  `{:no_pin_source, states}`, and a source that cannot answer refuses it.
- **If you match `t:StatifierPersistence.Executions.migration_finding/0`
  exhaustively**, add a clause for `{:timer_event_removed, state_id,
  event}`, or a catch-all.
- **If you run `StatifierPersistence.Testing.StorageConformance` against a
  storage adapter of your own that exports `lock_execution/3`**, your
  suite now runs one more case, "adapter: a door called from inside its
  own executor refuses before it reaches lock_execution/3". It is the
  0.21.0 re-entrancy case again, run through the default serialization
  strategy and so under your adapter's own lock: the nested door must
  refuse before it asks for the lock, whether your lock admits its own
  holder or would wait for it. It carries `@tag :postgres` with the two
  lock cases, so a host running `StatifierPersistence.Storage.Ecto` off
  Postgres now excludes five cases rather than four. An adapter that does
  not export `lock_execution/3`: **NONE**.

## 0.22 to 0.23

### 0.23.0

Schema: **NONE**. The `statifier` floor stays `~> 2.9`.

- **If a create, migration or tree migration can run while the same
  chart is being retired**, expect the one that loses the race to refuse.
  `StatifierPersistence.Executions.create/4` and `migrate/4` answer
  `{:error, {:chart_retired, info}}`, and `migrate_tree/4` answers
  `{:error, {:tree_refused, refusals}}` carrying that arm for the node,
  where before the write could land its execution on the retired chart;
  or `retire_chart/4` answers `{:error, {:pinned, counts}}`, where before
  it could retire a chart an execution was about to stand on. Both
  answers already existed. This holds on `StatifierPersistence.Storage.Ecto`
  over Postgres under the default serialization strategy, and on
  `StatifierPersistence.Storage.InMemory` with two differences there: a
  tree that loses at its write, rather than at its re-read of the chart,
  answers the bare `{:error, {:chart_retired, info}}`, and a create that
  loses at its insert is refused after its executor has run the create's
  effects. On another backend, or under a `serialization:` strategy of
  your own, the window is narrowed and not closed. A host that never
  retires a chart while writing to it: **NONE**.
- **If a tombstone read can meet a retirement of the same chart, or you
  call `Executions.create/4`, `migrate/4` or `migrate_tree/4` inside a
  transaction of your own**, expect waiting. On
  `StatifierPersistence.Storage.Ecto` over Postgres,
  `Storage.check_chart_retired/2` (so every create, migration and tree
  migration) takes the chart's shared advisory lock: a read waits for a
  retirement of the same chart that has not yet committed, and a write
  inside your own transaction holds the lock until you commit, so a
  retirement of that chart waits that long. A test under the Ecto SQL
  sandbox is one such transaction. No answer changes. The in-memory
  adapter and an Ecto repo on another backend take no such lock, and
  under a `serialization:` strategy of your own, outside a transaction of
  yours, the lock is held only for the read's own statement. What waits
  on what is in [What the chart lock reaches](chart-lock.md).
- **If your own two-key Postgres advisory locks use `1397769032` as their
  first key**, they now share a key space with the Ecto adapter's
  per-chart lock; pick another first key.
- **If you run `StatifierPersistence.Testing.StorageConformance` against a
  storage adapter of your own that exports `retire_chart/3`**, your suite
  now runs two more cases, a create and a migration whose hash is retired
  after their first check. They need no `lock_execution/3` and carry no
  tag.
- **If your executor writes through the store's repo and a step's
  position save can answer an error** (the only such error found on
  `StatifierPersistence.Storage.Ecto` is `{:error, :execution_not_found}`
  for a row gone from under the step), those writes now roll back with
  the step instead of committing without its position, and so does the
  step's input log entry, when the step runs under the default
  serialization strategy and its lock opened the outermost transaction.
  `StatifierPersistence.Executions.step/5` answers the same error as
  before; deliver the event again to re-drive the whole step. Inside a
  transaction of your own, under a `serialization:` strategy of your own,
  and on `StatifierPersistence.Storage.InMemory`, nothing changes: the
  step answers the same error and the rollback, if any, is yours. A
  budget-exhausted step still commits its `:failed` record. A host whose
  position saves never fail: **NONE**.

### 0.23.1

Schema: **NONE**, the `statifier` floor stays `~> 2.9`, and no
answer a host matches is added or removed.

- **If you run `StatifierPersistence.Testing.StorageConformance` from two
  or more async test modules against one Postgres database**, the suite
  no longer deadlocks (`40P01`) in the tombstone-check case or in the
  cases that retire a hash after a create's or a migration's first
  check: each module that uses the suite now retires chart hashes of its
  own, derived from the module's name. Nothing in your suite changes.

## 0.23 to 0.24

### 0.24.0

Schema: **NONE**. The `statifier` floor stays `~> 2.9`, and no answer a
host matches is added or removed.

- **If two stores share one Postgres database**, two hosts or two test
  suites each with its own charts table, they no longer wait on each
  other for a chart hash they share: the Ecto adapter's per-chart
  advisory lock is now keyed by the store (the charts table under its
  prefix) as well as the content hash. Every caller of one store still
  shares the lock, and creates, migrations and retirements on one store
  are ordered as in 0.23.0. The lock's first key, `1397769032`, is
  unchanged, so a host whose own two-key advisory locks use another
  first key, as "0.22 to 0.23" asks, sees no overlap it did not see
  before. What the lock reaches is in
  [What the chart lock reaches](chart-lock.md). A host with two stores
  in one database changes nothing to take this. A host with one store
  per database, or whose repo is not Postgres, sees no change at all:
  **NONE**.
- **If a test module of yours uses
  `StatifierPersistence.Testing.StorageConformance` and calls one of the
  helpers the suite defines in it** (`input_log_execution/2`, for one),
  add the prefix to the call: every attribute, function and nested
  module the suite puts into your module is now named under one reserved
  prefix, `conformance_` (`Conformance` for a nested module), and the
  suite's moduledoc states that prefix as the contract. The telemetry
  handler `__conformance_forward_adapter_call__/4` is now
  `conformance_forward_adapter_call/4`. A helper of your own that shared
  a name with one of the suite's no longer collides with it; one named
  under the prefix does. A module that calls none of the suite's
  helpers: **NONE**.

### 0.24.1

Schema: **NONE**, the `statifier` floor stays `~> 2.9`, and no
answer a host matches is added or removed.

A documentation release: no library code differs from 0.24.0, and the
`"~> 0.24.0"` pin already takes it. **NONE**.

### 0.24.2

Schema: **NONE**, the `statifier` floor stays `~> 2.9`, and no
answer a host matches is added or removed.

A documentation release: no library code differs from 0.24.1, and the
`"~> 0.24.0"` pin already takes it. This page is now listed in the
HexDocs sidebar, under Upgrading. **NONE**.

## 0.24 to 0.25

### 0.25.0

Schema: **NONE**. The `statifier` floor moves from `~> 2.9` to `~> 2.15`,
the first release carrying host function providers, and no answer a host
matches is removed. One arm is added to a tuple a host may match:
`{:function_providers, reason}`, and it is answered only when a host passes
the new `function_providers:` option and the list does not resolve.

- **If your `statifier` requirement allows 2.9 through 2.14**, move it to
  `~> 2.15`: `{:statifier, "~> 2.15"}`, or a looser one that still excludes
  every release before 2.15. A host that takes `statifier` only through
  this package needs no change in its own `mix.exs`, and `mix deps.update
  statifier` fetches 2.15. Nothing in
  `statifier_persistence` answers differently for a chart that calls no
  host function. What statifier itself changed between 2.9 and 2.15,
  including a document it now refuses to compile, is in statifier's
  CHANGELOG and upgrading page, which a host reads for the releases it
  skips.
- **If your charts call functions of your own in a `cond` or an `expr`**,
  give the list of your `Predicator.FunctionProvider` modules to
  `function_providers:` instead of stamping it by hand with
  `Statifier.MachineState.put_function_providers/2`. It goes in three
  places: on `StatifierPersistence.Executions.step/5`; inside `initialize:`
  on `StatifierPersistence.Executions.create/4`; and on
  `StatifierPersistence.Driver.new/3` as a driver-level default that each
  call may override. The package stamps the list on the loaded position
  beside `routes:`, `invoke_types:` and `send_types:`, so a resumed
  execution evaluates the call with no touch of
  `Statifier.MachineState` from you. A durable subchart child the driver
  creates does not inherit the list. A host that registers no function
  provider changes nothing: **NONE**.
- **If you pass `function_providers:` and match on the errors of
  `StatifierPersistence.Executions` or the driver**, add the
  `{:function_providers, reason}` arm to the match. A list that does not
  resolve is refused at the entry with `{:error, {:function_providers,
  reason}}`, before any lock, load or write, on `step/5`, `create/4`, and
  the driver's `create/3`, `send_event/4`, `done_invocation/5`,
  `failed_invocation/5` and `answer_parent/3`. `reason` is one of
  `{:not_a_list, value}`, `{:invalid_provider, entry, message}` and
  `{:shadowed_names, names}`
  (`t:StatifierPersistence.Executions.function_providers_reason/0`). A
  host that passes no list never sees the arm.
- **If you call `StatifierPersistence.Driver.start_child_at/6` on a driver
  that carries a `function_providers:` list**, add
  `{:refused, {:function_providers, reason}}` to the refusals you match: a
  list that does not resolve is refused there before any child is created
  or anything is written, in the door's own `{:refused, reason}` shape. It
  emits no `[:statifier_persistence, :child, :refused]` event. A driver
  with a list that resolves, or with none, starts children as before.
