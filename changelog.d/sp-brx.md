### Added

- `StatifierPersistence.Storage.Adapter.pin_counts/3`, `pinned?/1` and `sources_pinned?/1`, with the `pin_counts/0`, `execution_counts/0` and `source_counts/0` types: the one shape a `retire_chart/3` refusal carries and the predicate for whether what an adapter counted is a pin, so a third-party adapter builds its refusal through them instead of inventing a second shape for one answer.
