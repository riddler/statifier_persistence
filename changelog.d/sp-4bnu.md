### Fixed

- `StatifierPersistence.Executions.migrate_tree/4` on the Ecto adapter
  answers `{:error, :execution_not_found}` for a unit naming an execution
  that is not stored, as the in-memory adapter does, instead of
  `{:error, {:adapter, :rollback}}`. The refusal writes nothing and no
  longer aborts a caller's own enclosing transaction.
