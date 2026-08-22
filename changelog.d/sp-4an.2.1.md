# sp-4an.2.1

## Added

- Run records on the storage contract: `StatifierPersistence.Storage.Adapter`
  gains `insert_run/2`, `fetch_run/2`, and `update_run/2` callbacks with
  `run_record`/`run_status` types and the `:run_exists` / `:run_not_found`
  error arms; `StatifierPersistence.Storage.InMemory` implements them.
- Guarded run access on the facade: `StatifierPersistence.Storage.insert_run/5`,
  `update_run/5`, `fetch_run/2`, and `load_run_position/3` (identity-guarded,
  with the `:run_position_missing` arm for a run persisted without a
  position).
- Run-record conformance tests in
  `StatifierPersistence.Testing.StorageConformance`, so downstream adapters
  inherit the same contract checks.
