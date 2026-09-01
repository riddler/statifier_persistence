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
- `StatifierPersistence.Run.Linkage` records a durable subchart child's
  parent under a reserved, package-owned key in run `metadata` (ADR-0008
  decision 2): the parent's run id, the invocation id, a child index, and
  a mandatory pin of the child's own chart identity. `Runs.create/4` gains
  a `linkage:` option that stores it and raises `ArgumentError` if a host's
  own `metadata:` tries to write into the reserved key.
