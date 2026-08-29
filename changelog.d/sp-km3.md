### Added

- `use StatifierPersistence.Ecto` accepts a `:blob_type` option to put a custom Ecto type on the three blob columns (`identity_blob`, `chart_blob`, `position_blob`), enabling encryption at rest with no wrapping adapter.
