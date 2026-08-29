### Added

- `StatifierPersistence.Runs.create/4` and
  `StatifierPersistence.Storage.insert_run/5` accept an optional
  `metadata:` map of string keys, stored opaquely beside the run record
  and returned by `fetch_run/2` unchanged (ADR-0006). Host identities
  only, never personal data: blob encryption does not reach this column.
- `StatifierPersistence.Storage.Adapter` gains the optional
  `supports_metadata?/1` callback and a `metadata` field on `run_record`.
  An adapter that does not export it refuses a non-empty map at create
  with `{:error, :metadata_unsupported}`; an empty or absent map is never
  refused, so every existing adapter stays conformant unchanged.
- `StatifierPersistence.Storage.metadata_supported?/1` and
  `check_metadata/2` report whether a store's adapter can hold metadata,
  without writing anything.
- `StatifierPersistence.Storage.Ecto.list_runs_by_metadata/2` lists the
  runs whose metadata contains every given key/value pair.
- Migration V02 adds a nullable `jsonb` `metadata` column to the runs
  table, and `StatifierPersistence.Ecto.Migrations.up/1` accepts `from:`
  so a host already on V01 applies later versions in its own second
  migration.
- `StatifierPersistence.Testing.StorageConformance` gains metadata cases:
  a conformant adapter either round-trips the map or refuses it at open,
  and never silently drops it.
