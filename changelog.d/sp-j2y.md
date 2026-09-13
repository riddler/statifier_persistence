### Changed

- **Breaking for hosts.** The durable table is now `statifier_executions`,
  and its identity column - in that table and in `statifier_inputs` - is now
  `execution_id` (ADR-0011 decision 3). A new migration, **V06**, makes the
  move on an existing database: it renames the table, both columns, both
  unique indexes and the `metadata` GIN index **in place**, copying no data,
  and it is a no-op on a database created at 0.12.0 or later. Run
  `StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 6)`
  from an ordinary host migration; a fresh install gets the new names from
  V01 and needs nothing extra. That one-line upgrade is for an install
  already at V05: one that still owes V02, V03 or V04 runs
  `up(for: MyApp.Persistence, from: 6, version: 6)` **first** and then
  `up(for: MyApp.Persistence, from: 2, version: 5)`, because V02-V04 alter
  the executions table, which on such a database carries that name only
  once V06 has renamed it. Rename the table in any raw query, view,
  materialized view, hand-written Ecto schema or dashboard of your own that
  names it - it is `statifier_executions` on both paths. "In place" is exact
  for the table and the columns on every backend; off Postgres, which has no
  `ALTER INDEX ... RENAME TO`, the two unique indexes are dropped and
  declared again under their new names instead, which still copies no data.

- **Breaking for a host that overrides table names.** The `:tables` key for
  this table is now `:executions`; `:runs` is rejected with
  `ArgumentError`, and no alias ships for a release. Rename the key in your
  `use StatifierPersistence.Ecto` options. A `:tables` override's *value* is
  untouched: V06 renames the columns and indexes under whatever name you
  gave, and the table keeps that name.

- **Rolling back below V06 drops the tables under their new names.**
  `StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence,
  version: 6)` undoes V06 alone and leaves an upgraded install back on the
  pre-0.12.0 names. A rollback that continues below version 6 skips V06's
  rename, because V01-V05 are rewritten to the new noun and drop the tables
  under those names - so `down(for: MyApp.Persistence)` still removes
  everything this package owns, on a fresh install and on an upgraded one
  alike. What it is not is a downgrade: to run 0.11.x again, restore a
  backup or migrate up with 0.11.x's own migrations.

- **An in-flight durable subchart child does not survive the upgrade.** A
  child created under 0.11.x carries its parent link in `metadata` under the
  pre-0.12.0 key, and V06 renames no stored value - it is a catalog
  operation and copies no data. `Execution.Linkage.from_metadata/1`
  therefore answers `:no_linkage` for such a child, and its completion no
  longer settles its parent's fan-out. **Drain your in-flight children
  before upgrading**: let every durable subchart child reach a terminal
  status under 0.11.x, then upgrade. Children created at 0.12.0 or later are
  unaffected.

- The migration helper now knows six versions:
  `StatifierPersistence.Ecto.Migrations.expected_version/0` answers `6`.

- The surrogate-key table map renames with the table key:
  `t:StatifierPersistence.Ecto.KeyGenerator.table/0` is now
  `:charts | :positions | :executions | :inputs`, and the shipped UXID
  generator's prefix for that table is `"exec"` (it was already `"exec"` in
  0.11.x under the old key). A host with its own `Ecto.KeyGenerator`
  implementation renames the atom it matches on.
