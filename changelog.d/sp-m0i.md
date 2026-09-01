### Added

- `StatifierPersistence.Telemetry` emits the fourteen `[:statifier_persistence,
  ...]` events ADR-0009 specifies - the durable step as a `:start`/`:stop` pair,
  the per-run lock wait, every storage-adapter call, identity refusals, the run
  lifecycle, executor failures, and the durable-subchart seam - and `events/0`
  returns every name for a bridge to attach to.
- Adds a direct `:telemetry` dependency (already present transitively through
  `statifier`, so no lock file grows).
