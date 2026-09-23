### Added

- `StatifierPersistence.Executions.migrate_tree/4` emits `[:statifier_persistence, :execution, :migrated]` once per node it re-pins, the children's before the root's, after its one store unit has returned, with the same keys `migrate/4` emits; a refused or parked tree emits it for no node.
- `StatifierPersistence.Testing.StorageConformance` gains two tree migration cases for an adapter that exports `write_tree_migration/2`: every re-pin and park in the list lands with only a moved child's linkage pin rewritten in its metadata, and a list that cannot land one write lands none.
