### Added

- `StatifierPersistence.Runs.cancel/3` retains a run's record and position
  while moving its status to the new terminal `:cancelled` state - a
  host-driven transition alongside `fail/4`, and one an already-terminal run
  discards rather than re-writes.
- An adapter can now optionally export `list_runs_by_metadata/2` to let a
  host enumerate the runs whose metadata contains a given set of key/value
  pairs; `StatifierPersistence.Storage.list_runs_by_metadata/2` and
  `child_listing_supported?/1` expose this through the facade, returning
  `{:error, :child_listing_unsupported}` for an adapter that does not
  support it. `StatifierPersistence.Storage.InMemory` implements it now,
  alongside the existing `StatifierPersistence.Storage.Ecto` support.
