### Added

- A fifth execution status, `:needs_migration`: an execution parked on the chart it was already pinned to. It is not terminal, it takes no event, `fail/4` and `cancel/3` end it as they end an `:active` one, and it pins its chart against a retirement as an `:active` one does. `StatifierPersistence.Executions.migrate/4` under `on_failure: :park` is the one thing that parks an execution.
- `StatifierPersistence.Executions.unpark/3` puts a `:needs_migration` execution back to `:active` at the position it was parked at, on its own chart, writing its status and nothing else; an `:active` execution answers `{:ok, execution}` unchanged and a terminal one is discarded.

### Changed

- **Breaking** for a host that matches `t:StatifierPersistence.Storage.Adapter.execution_status/0` exhaustively: add a clause for `:needs_migration`, or a catch-all, to every `case` over an execution's status.
- **Breaking** for a host that matches the drained query's answer as a closed map: `StatifierPersistence.Executions.executions_on/2` and `StatifierPersistence.Storage.count_executions_by_content_hash/2` answer a sixth key, `needs_migration`, and a `{:pinned, counts}` refusal carries it under `executions`.
- **Breaking** for a storage adapter outside this package that stores the status or implements `count_executions_by_content_hash/2` or `retire_chart/3`: store and read back `:needs_migration`, count it under its own key, count a durable child's pin while its parent is `:active` or `:needs_migration`, and refuse to retire a chart a `:needs_migration` execution is on, or one a durable child's pin names while its parent is `:needs_migration`, as for an `:active` one. The conformance suite checks each.
- A delivery to a `:needs_migration` execution through `StatifierPersistence.Executions.step/5` or any `StatifierPersistence.Driver` door answers `{:error, {:needs_migration, execution}}`: nothing is appended, executed or written, and retrying the delivery after the execution leaves the arm is the host's. Only `StatifierPersistence.Executions.migrate/4` under `on_failure: :park` parks an execution, so a host that never parks never sees this arm.
- A durable child's linkage pin counts toward `children`, and refuses a retirement, while its parent is `:needs_migration` as well as `:active`.
