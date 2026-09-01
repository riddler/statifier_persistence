# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.5.0] 2026-09-01

Feature release: the durable step is observable, and a `:dispatch` fun can
see the whole `<invoke>` it is being handed.

### Added

- `StatifierPersistence.Driver.dispatch_context/0` carries `:invoke`, the whole
  `Statifier.Effect.Invoke` being dispatched, so a `:dispatch` fun can read the
  element's `src` - the document id a subchart handler resolves its child chart
  by - along with `content`, `autoforward`, and the step counters.
- `StatifierPersistence.Telemetry` emits the fourteen `[:statifier_persistence,
  ...]` events ADR-0009 specifies - the durable step as a `:start`/`:stop` pair,
  the per-run lock wait, every storage-adapter call, identity refusals, the run
  lifecycle, executor failures, and the durable-subchart seam - and `events/0`
  returns every name for a bridge to attach to.
- Adds a direct `:telemetry` dependency (already present transitively through
  `statifier`, so no lock file grows).

## [0.4.0] 2026-09-01

Feature release: durable subcharts (ADR-0008) - an `<invoke>` may start a
child chart as an ordinary durable run, the parent rests holding no process
while the child runs, and leaving the invoking state cancels the child
subtree.

**Breaking for storage adapters**: `run_status/0` gains a fourth terminal
value, `:cancelled`. An adapter that encodes run statuses by an exhaustive
match must add a clause for it before upgrading, or cancelled runs will fail
to persist. The two adapters in this package already handle it.

### Added

- Durable subcharts (ADR-0008): a `<invoke>` whose `:dispatch` fun answers
  `{:start_child, invoke, {:invoke, invoke}}` now starts the subchart as an
  ordinary durable run instead of being refused, and the parent rests holding
  no process for as long as the child takes.
- `StatifierPersistence.Run.Linkage` records a child's parent run id,
  invocation id, and a mandatory pin of the child's chart identity under a
  reserved key in the child's run `metadata`.
- `StatifierPersistence.Runs.create/4` takes `linkage:`, and raises
  `ArgumentError` when a host's own `metadata:` writes into the reserved key.
- `StatifierPersistence.Driver.new/3` takes `chart_resolver:`, which lets a
  finished child answer its parent through the existing `done_invocation/5`
  and `failed_invocation/5` doors.
- `StatifierPersistence.Runs.cancel/3` and `cascade_cancel/3` cancel a
  parent's child subtree when it leaves the invoking state, retaining every
  record and position.
- Storage adapters may export the optional `list_runs_by_metadata/2`, reached
  through `StatifierPersistence.Storage.list_runs_by_metadata/2` and
  `child_listing_supported?/1`; a store whose adapter does not export it
  refuses a durable subchart before any write.
- `StatifierPersistence.Storage.InMemory` implements `list_runs_by_metadata/2`,
  which `StatifierPersistence.Storage.Ecto` already supported.

### Changed

- `StatifierPersistence.Storage.Adapter.run_status/0` gains a fourth terminal
  value, `:cancelled`. An adapter that encodes statuses by an exhaustive match
  must add a clause for it, or cancelled runs will fail to persist.
- `StatifierPersistence.Run` gains `donedata`, set only on the step that
  completes a run and `nil` everywhere else.

## [0.3.0] 2026-09-01

Feature release: an asynchronous invocation seam on the durable driver - a
dispatch may answer `:pending` and the run rests holding no process, with
public doors that answer the invocation later from any process or node.

### Added

- `StatifierPersistence.Driver`'s `:dispatch` fun may answer `:pending`: the
  call was started asynchronously and the run rests durably with the
  invocation live, holding no process (ADR-0007).
- `StatifierPersistence.Driver.done_invocation/5` and
  `StatifierPersistence.Driver.failed_invocation/5` answer a pending
  invocation later, from any process or node, building the same
  `done.invoke` / `error.communication.invoke` events a live
  `Statifier.Session` builds. An answer for an invocation the chart has
  cancelled is `{:discarded, run}`, decided from the persisted position
  inside the run's serialization strategy.
- `StatifierPersistence.Runs.step/5` accepts an event builder - a fun over
  the loaded position returning `{:ok, event}` or `:discard` - anywhere it
  accepts a `Statifier.Event`.

### Changed

- The context handed to a `:dispatch` fun carries `invoke_id`, the
  invocation id an asynchronous host keys its work by and hands back to the
  re-entry doors.

## [0.2.0] 2026-08-31

Feature release: a durable run-to-quiescence driver, opaque run metadata,
and a custom blob type for encryption at rest.

### Added

- `StatifierPersistence.Driver` drives a durable run to quiescence over
  `StatifierPersistence.Runs`: it performs each `<invoke>` through a
  host-supplied dispatch fun inside the step that emitted it, then steps
  every answer back in until the chart rests. Hosts that hand-rolled this
  loop can delete it.
- `StatifierPersistence.Driver` builds an invocation's answer events -
  `done.invoke.<id>` and `error.communication.invoke.<id>`, `origin` and
  `origintype` included - field for field from `Statifier.Session`'s own
  `done_invocation/3` and `failed_invocation/3`, so a chart sees the same
  event in a session and out of storage. A conformance test answers one
  document both ways and compares what each chart saw.
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
- `use StatifierPersistence.Ecto` accepts a `:blob_type` option to put a custom Ecto type on the three blob columns (`identity_blob`, `chart_blob`, `position_blob`), enabling encryption at rest with no wrapping adapter.

### Changed

- Requires `statifier` `~> 2.2 and >= 2.2.1` rather than `~> 2.0`: 2.2.1 is
  the first release carrying the queue-discard-on-exit fix the completion
  conformance cases need. (An interim git-ref pin served between 2.2.0 and
  that release.)

### Fixed

- A run whose top-level `<final>` is reached while sibling `done.state.*` events
  are still queued now persists as `completed`, instead of raising
  "loop bug: non-quiescent MachineState reached the persist tail". The same
  holds for a top-level `<final>` whose `<donedata>` expression fails.
- `StatifierPersistence.Runs.create/4` passes only its `metadata:` pair to
  `StatifierPersistence.Storage.check_metadata/2`, whose contract is the
  narrower `[Storage.run_write_opt()]`. Handing the whole option list over
  made dialyzer derive a success typing for `create/4` that accepted no
  `executor:` at all, so an embedder had to suppress "will never return" on
  every correct call; that suppression can now be deleted.

## [0.1.3] 2026-08-27

Docs release: README and guide refresh onto the family's canonical example
domains. No library code changes.

### Changed

- The README now walks a full worked run in the card-processing domain -
  load, step, execute effects, persist - and continues it across a restart,
  with a new module map; the examples are executed by a test so they cannot
  drift from the real API.
- Example domains follow the family rule: card processing and the signup
  wizard with A/B testing only.
- Agent tooling: gate attestation points at `mix quality.verify` (shipped
  by ex_quality 0.14) instead of a retired local task.

## [0.1.2] 2026-08-24

Docs release: the hexdocs/README overhaul from PR #20. No library code changes.

### Changed

- Hexdocs no longer publishes the ADRs: the ADR extras and their
  `groups_for_extras` entry are removed, so the published docs are the README,
  this changelog, and the restart-demo guide.
- `ex_doc` is pinned to `~> 0.40`, and `CHANGELOG.md` is listed in
  `skip_undefined_reference_warnings_on`; `mix docs` now completes with zero
  warnings.
- The README gains the standard badge row (CI, hex.pm version/downloads,
  hexdocs, license) and a documentation index line linking the published
  restart-demo guide.

## [0.1.1] 2026-08-24

Patch release: the key-generator compile-race fix from PR #18.

### Fixed

- Custom key-generator validation in `use StatifierPersistence.Ecto` no longer
  fails spuriously when the generator module is still being compiled by the
  host's parallel compiler; validation now waits for in-flight compilation
  (`Code.ensure_compiled/1`) instead of checking `Code.ensure_loaded?/1`.

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
