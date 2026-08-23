# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.1.0] 2026-08-22

First release: the persistence-first execution loop for the
[statifier](https://hex.pm/packages/statifier) statechart engine - load a
persisted position, step it, execute the effects, persist - packaged as a
storage-adapter behaviour with an identity guard, an in-memory reference
adapter, a run lifecycle, and an Ecto/Postgres layer, all covered by one
conformance suite downstream adapters inherit.

### Added

- `StatifierPersistence.Storage.Adapter`, the storage contract, including
  run records: `insert_run/2`, `fetch_run/2`, and `update_run/2` callbacks
  with `run_record`/`run_status` types and the `:run_exists` /
  `:run_not_found` error arms; `StatifierPersistence.Storage.InMemory` is
  the reference implementation.
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
  and discards on a terminal run - backed by the status-only writer
  `StatifierPersistence.Storage.update_run_status/4`.
- Pluggable per-run serialization: the `StatifierPersistence.Serialization`
  behaviour (`with_run/3`), selected per lifecycle call with
  `serialization: {module, config}` on `Runs.create/4`, `step/5`, and
  `fail/4`. The default strategy,
  `StatifierPersistence.Serialization.AdapterLock`, delegates to the
  optional adapter callback
  `StatifierPersistence.Storage.Adapter.lock_run/3` (implemented by
  `InMemory`, conformance-tested when exported) and refuses with
  `{:error, {:serialization, :not_supported}}` when the adapter does not
  export it.
- `use StatifierPersistence.Ecto`: compile-time configuration on the host's
  module (`repo:`, `key:`, `table_prefix:`, `tables:`, `prefix:`) that
  defines `Chart`, `Position`, and `Run` schema modules and exposes the
  resolved config via `__statifier_persistence__/1`. Requires the optional
  `ecto_sql` dependency.
- `StatifierPersistence.Ecto.KeyGenerator`: the behaviour a surrogate-key
  scheme implements, with `:uxid` (default), `:uuid` (UUIDv7), `:bigserial`,
  and `{module, opts}` resolved through `resolve/1`.
- `StatifierPersistence.Ecto.Migrations`: the versioned migrations helper
  (`up/1`, `down/1`, taking `for: HostModule` or the same literal options
  `use` takes) that creates the `charts`/`positions`/`runs` tables from the
  same resolved config the schemas use.
- `StatifierPersistence.Storage.Ecto`: the Postgres storage adapter over
  the schemas a host generates with `use StatifierPersistence.Ecto`
  (`Storage.new(Storage.Ecto, persistence: MyApp.Persistence)`). Passes
  the same conformance suite as the in-memory reference adapter; engine
  identities stored verbatim; `:run_exists` enforced atomically by the
  unique index.
- `Storage.Ecto.isolate/1`: with `sandbox: true`, wraps each test in its
  own `Ecto.Adapters.SQL.Sandbox` checkout - the hook host test suites
  (and this package's conformance suite) isolate through.
- `Storage.Ecto.lock_run/3`: per-run mutual exclusion as a
  transaction-scoped `pg_advisory_xact_lock` plus a `SELECT ... FOR
  UPDATE` row lock (ADR-0004 as amended), consumed by
  `Serialization.AdapterLock`.
- `uxid` is a required dependency (the default key scheme works out of
  the box); `ecto_sql` is optional and the package compiles without it.
