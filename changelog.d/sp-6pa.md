### Added

- `StatifierPersistence.Testing.StorageConformance` gains a retirement case for a durable child's pin: an adapter that exports `retire_chart/3` and `supports_metadata?/1` must refuse to retire a chart named by a terminal child's linkage pin while that child's parent is `:active`, and keep the chart's bytes.
