### Added

- Every public door of `StatifierPersistence.Executions` that takes an execution id (`create/4`, `step/5`, `fail/4`, `cancel/3`, `unpark/3`, `migrate/4`, `migrate_tree/4`, `inputs/2`) answers `{:error, {:reentrant_step, execution_id}}` when called for an execution whose executor is running in the calling process, instead of letting the outer step overwrite the nested call's write with nothing reported; a host that never calls back into the execution it is stepping sees no change. Code that matches `t:StatifierPersistence.Executions.error/0` exhaustively gains one arm.
