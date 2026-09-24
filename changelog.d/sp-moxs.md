### Added

- A telemetry event, `[:statifier_persistence, :execution, :step, :exception]`, closes the step span in place of `:stop` when a drive raises, throws or exits (a host executor or event builder included), carrying `execution_id`, `entry`, `span_ref`, `kind`, and a `reason` and `stacktrace` narrowed so no raised value or call argument travels; the raise still reaches the caller unchanged. `StatifierPersistence.Telemetry.events/0` returns eighteen names.
- `StatifierPersistence.Telemetry.execution_step_exception/2`, the emitter of `[:statifier_persistence, :execution, :step, :exception]`.

### Fixed

- A raise from a host executor or event builder during a drive through `StatifierPersistence.Executions` or `StatifierPersistence.Driver` no longer leaves the `[:statifier_persistence, :execution, :step, :start]` span open with no closing event.
