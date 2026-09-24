# Upgrading a host from 0.13 to 0.17

This page says what a host changes to move `statifier_persistence` from
0.13.0 to 0.17.0, one minor at a time. A host here is the code that
embeds the package: the module that calls `use StatifierPersistence.Ecto`,
the migrations it runs, the options it passes to
`StatifierPersistence.Executions` and `StatifierPersistence.Driver`, the
telemetry handlers it attaches, and any storage adapter of its own. What
each release added is in [CHANGELOG.md](../CHANGELOG.md); this page lists
only what a host has to do about it, and says **NONE** where the answer is
nothing.

Take the minors in order, and move the pin with each one, as the README
recommends: `{:statifier_persistence, "~> 0.14.0"}`, then `"~> 0.15.0"`,
then `"~> 0.16.0"`, then `"~> 0.17.0"`. The `statifier` floor stays
`~> 2.6` for every step on this page.

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
`StatifierPersistence.Ecto.Migrations` documentation first. No release before
0.17.0 adds a migration; 0.17.0 does (V08, at the end).

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
  before its tables exist; see "Placing a host column at a fixed position"
  in the README.

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
