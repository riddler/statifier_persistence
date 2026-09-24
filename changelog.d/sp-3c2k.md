### Added

- `StatifierPersistence.Executions.unpark/3` emits `[:statifier_persistence, :execution, :unparked]` (`execution_id`, `content_hash`) when it puts a `:needs_migration` execution back to `:active`, and `[:statifier_persistence, :execution, :lock]` for its wait on the execution's exclusion; `StatifierPersistence.Telemetry.events/0` returns nineteen names.
