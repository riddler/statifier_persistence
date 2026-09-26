### Added

- `prune_scope:` on `use StatifierPersistence.Testing.StorageConformance`, for authors of a storage adapter of their own: given `inside:` and `outside:` scopes and a `place:` function that writes the scope's columns onto an execution's rows, the suite generates one more pruning case proving that a scoped `c:StatifierPersistence.Storage.Adapter.prune_executions/4` batch clears the execution inside the scope and leaves the one outside it whole. The option shipped in 0.19.0, whose section did not name it; nothing changes in this release.
