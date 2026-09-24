### Fixed

- `StatifierPersistence.Executions.migrate_tree/4` on the Ecto adapter
  answers `{:error, :execution_not_found}` for a unit naming an execution
  that is not stored, as the in-memory adapter does, instead of
  `{:error, {:adapter, :rollback}}`. That old answer came under the
  default serialization, whose per-execution lock is a transaction; under
  a serialization strategy that opens no transaction, 0.15.0 already
  answered `{:error, :execution_not_found}`. The refusal writes nothing
  and no longer aborts a caller's own enclosing transaction.
