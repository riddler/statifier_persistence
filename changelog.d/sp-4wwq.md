### Changed

- A dry run of `StatifierPersistence.Executions.migrate_batch/3` started from inside an executor, or an event builder, answers `{:would_refuse, {:reentrant_step, execution_id}}` for the execution being stepped, before it is read, as the apply refuses it through `migrate/4`. Before, the dry run waited on its own caller's lock on the in-memory adapter and previewed the execution from inside the outer step on the Ecto adapter. The other executions the batch lists are previewed as before, and a dry run called from anywhere else sees no change.
