### Changed

- `StatifierPersistence.Storage.Ecto.list_runs_by_metadata/2` and
  `list_run_states_by_metadata/2` now return
  `{:error, :metadata_unsupported}` on a backend that is not Postgres,
  where they previously raised from the driver on `jsonb` containment SQL
  it cannot parse. Both consult `supports_metadata?/1` before issuing
  anything, so a host calling the raw adapter callback gets the same clean
  refusal `StatifierPersistence.Storage` already gave through the facade.
  A behaviour change on two adapter callbacks: code rescuing the raise
  sees a tagged tuple instead. Nothing changes on Postgres, and the facade
  is untouched.
