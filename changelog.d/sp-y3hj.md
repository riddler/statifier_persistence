### Added

- `StatifierPersistence.Executions.migrate_tree/4` moves a parent execution and its durable children onto newer charts together: one plan per node, every node validated before any is written, children first, all in one store unit or nothing, and under `on_failure: :park` every named node parks.
- A moved child's linkage pin is rewritten to the chart it now walks, so the old chart is no longer counted as pinned by it.
- The storage adapter behaviour gains the optional `supports_tree_migration?/1` and `write_tree_migration/2` callbacks, implemented by the in-memory and Ecto adapters; an adapter without them makes `migrate_tree/4` answer `{:error, :tree_migration_unsupported}`.
- `StatifierPersistence.Storage.tree_migration_supported?/1` and `StatifierPersistence.Storage.write_tree_migration/2`, and `t:StatifierPersistence.Storage.error/0` gains `:tree_migration_unsupported`.
