### Added

- `StatifierPersistence.Migration.Plan`: the plan that moves an execution from one chart to another, as data (ADR-0013). `new/1` builds one and refuses a malformed plan naming the field; `to_map/1` and `from_map/1` are its one JSON-safe encoding, string keys only; `validate/3` checks a plan against the from and to machines and answers every finding at once. `StatifierPersistence.Executions.migrate/4` applies one to an execution.
