### Added

- `StatifierPersistence.Migration`, a documentation module for the namespace: what moving an execution onto another chart is, which module holds the plan and which function applies it, and that it is not `StatifierPersistence.Ecto.Migrations`, the schema-migration helper.
- `StatifierPersistence.Telemetry.execution_migrated/1`, the emitter of `[:statifier_persistence, :execution, :migrated]`, beside the package's other documented emitters.
