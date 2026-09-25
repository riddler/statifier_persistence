### Added

- `scope:` on `StatifierPersistence.Retention.prune/3`: a keyword list of column equalities over columns you placed with `:leading_columns`, such as `scope: [tenant_id: tenant_id]`, that confines the prune to the rows holding every one of them; each batch's selection, input log check, input log delete and position blob update carries the equalities, so a prune run inside one partition's transaction touches no other partition. Without `scope:` the prune is unchanged. The in-memory adapter answers `{:error, :unscoped_adapter}` for a scope, and `StatifierPersistence.Storage.prune_executions/4` takes the scope as its fourth argument, defaulting to `[]`.

### Changed

- **Breaking** for a storage adapter of your own that implements `c:StatifierPersistence.Storage.Adapter.prune_executions/3`: the optional callback is now `prune_executions/4`, its fourth argument the scope, `[]` when the host gave none, and an adapter still exporting `prune_executions/3` is no longer counted as declaring pruning, so `prune/3` answers `{:error, :execution_pruning_unsupported}` for it. Add the fourth argument; an adapter that cannot confine a batch to a scope answers `{:error, :unscoped_adapter}` for any scope that is not `[]`, and a host matching `t:StatifierPersistence.Storage.Adapter.error/0` exhaustively adds a clause for that arm.
