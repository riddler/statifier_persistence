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
- The run lifecycle as a library: `StatifierPersistence.Runs.create/4` and
  `step/5` drive the load -> re-stamp -> step -> execute -> persist loop
  over durable run records, handing effects to a host-supplied
  `StatifierPersistence.Executor` (behaviour or arity-2 fun) and returning
  the host-facing `StatifierPersistence.Run` struct; events to a terminal
  run come back as `{:discarded, run}`.
- Failure semantics on the loop: executor failures on actionable effects
  re-enter the chart as `error.communication` events (single wave per step,
  observational failures discarded); effect execution is at-least-once, with
  a failed persist re-driving the same event and re-emitting the same
  effects under identical deterministic keys; budget exhaustion persists a
  `:failed` run (position untouched) and returns
  `{:error, {:budget_exhausted, payload}}`.
- `StatifierPersistence.Runs.fail/4`, the host-driven abandonment: marks an
  active run `:failed` with a reason, leaves the stored position untouched,
  and discards on a terminal run - backed by the new status-only writer
  `StatifierPersistence.Storage.update_run_status/4`.
- Pluggable per-run serialization: the `StatifierPersistence.Serialization`
  behaviour (`with_run/3`), selected per lifecycle call with
  `serialization: {module, config}` on `Runs.create/4`, `step/5`, and
  `fail/4`. The default strategy,
  `StatifierPersistence.Serialization.AdapterLock`, delegates to the new
  optional adapter callback
  `StatifierPersistence.Storage.Adapter.lock_run/3` (implemented by
  `InMemory`, conformance-tested when exported) and refuses with
  `{:error, {:serialization, :not_supported}}` when the adapter does not
  export it.
