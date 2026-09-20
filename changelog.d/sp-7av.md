### Added

- `StatifierPersistence.Storage.check_chart_retired/2`, which answers the retired arm for a machine's own content hash without writing anything.

### Changed

- `StatifierPersistence.Executions.create/4` refuses a chart a retirement has tombstoned with `{:error, {:chart_retired, info}}`, before it writes an execution row or executes an effect.
