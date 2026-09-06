# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.10.0] 2026-09-06

Feature release: a durable subchart child failed from outside the
interpreter now settles its parent's pending `<invoke>` instead of leaving
it hanging forever. `StatifierPersistence.Runs.fail/4` takes a `driver:`
option and answers the parent itself, and
`StatifierPersistence.Driver.resolve_and_answer_parent/3` is the public
form of that answer for a caller with no drive of the child to hang it
off. Alongside it, `StatifierPersistence.Ecto.Migrations.expected_version/0`
names the newest migration version this package knows, for a host whose
schema is hand-written DDL and which therefore has to check for itself
that its tables are current.

### Added

- `StatifierPersistence.Runs.fail/4` takes a `driver:` option: a durable
  subchart child failed from outside the interpreter now answers its
  parent's `<invoke>` with the failure instead of leaving it pending
  forever (ADR-0008's note on the outside-fail seam).
- Adds `StatifierPersistence.Driver.resolve_and_answer_parent/3`, the
  public form of the automatic answer - resolve the parent's chart through
  `chart_resolver:`, then answer through `answer_parent/3` - for a caller
  that has no drive of the child to hang it off.
- `StatifierPersistence.Ecto.Migrations.expected_version/0` returns the
  newest migration version this package knows, for a host whose schema is
  hand-written DDL rather than a delegated migration and which therefore has
  to check for itself that its tables are current. There is no
  `assert_version!/1` to go with it: the package records no version marker in
  a repo's schema, so the comparison stays the host's - the function's docs
  say why.

### Documentation

- ADR-0010 takes a note answering whether a host needs the V05 input log
  table at all. An adapter that does not export the optional input-log
  callbacks never touches it - a host on one caps its migration at V04 in
  both directions rather than carrying an empty table - while a host storing
  through `StatifierPersistence.Storage.Ecto` needs it unconditionally,
  because that adapter declares input-log support without probing.

## [0.9.0] 2026-09-06

Feature release: a durably stepped run can now keep a verbatim log of every
input its interpreter saw, and a fan-out's settlement is visible in
telemetry. The storage-adapter behaviour gains three optional input-log
callbacks (`supports_input_log?/1`, `append_input/3`, `list_inputs/2`) and
`StatifierPersistence.Runs.inputs/2` reads the log back; `Storage.Ecto`
implements them on Postgres and SQLite alike through migration V05, with an
`input_log_cap:` bound and no log at all for an adapter that does not export
the callbacks (ADR-0010, accepted). Two new events,
`[:statifier_persistence, :child, :recorded]` and `:settled`, surface the
per-child answers and the settlement decision that reach no door, and
`child.answered`'s `outcome` is now the invocation's rather than the door's,
so a fan-out that failed no longer reports `:done`. And
`Storage.Ecto.list_runs_by_metadata/2` and `list_run_states_by_metadata/2`
refuse cleanly with `{:error, :metadata_unsupported}` off Postgres instead
of raising from the driver.

### Added

- Adds an optional per-run input log to the storage-adapter behaviour
  (`supports_input_log?/1`, `append_input/3`, `list_inputs/2`): an adapter
  that exports them records every input a run's interpreter saw - the
  verbatim `%Statifier.Event{}`, the public door it entered by, and a
  dense zero-based ordinal - which is what an offline replay of a durably
  stepped run needs (ADR-0010).
- Adds `StatifierPersistence.Runs.inputs/2` and
  `StatifierPersistence.Storage.input_log_supported?/1`,
  `append_input/4` and `list_inputs/2` for reading and writing that log.
- Adds migration V05, the input log table, on Postgres and SQLite alike;
  `StatifierPersistence.Storage.Ecto` implements all three callbacks and
  takes an `input_log_cap:` option that bounds a run's log and closes it
  with a marker entry rather than truncating it silently. The default is
  `:infinity`.
- `:blob_type` now reaches the new `input_blob` column. An event's `data`
  is host payload, so turning the log on is a data-retention decision:
  an adapter that does not export `supports_input_log?/1` keeps no log
  and behaves exactly as it did before.
- Adds `[:statifier_persistence, :child, :recorded]`, once per fan-out
  child answer written under the parent's settlement exclusion. Every
  index but the settling one records an answer that reaches no door, so
  this is the only surface those answers appear on (ADR-0009's sp-8wv
  amendment).
- Adds `[:statifier_persistence, :child, :settled]`, once per settlement
  decision, carrying the invocation's `policy`, the `:answer` /
  `:not_yet` decision, and the completed / failed / cancelled / unstarted
  tallies it was decided from.
- `[:statifier_persistence, :run, :step, :stop]` now carries `invoke_id`
  and `child_count`, `nil` on an ordinary drive and set on the
  `entry: :answer_parent` step, so the step span that delivers a whole
  fan-out's assembled answer is recognisable as that one.

### Changed

- `[:statifier_persistence, :child, :answered]`'s `outcome` is now the
  **invocation's** for a fan-out, not the door's: `:failed` when any index
  failed. A fan-out always answers its parent through `done_invocation/5`
  - the failure shape is inside each entry - so the event previously said
  `outcome: :done` for a settlement that had failed. It also gains
  `child_count` and `failed_count`, both `nil` for a single-child
  subchart, which is not an invocation with a width. A consumer counting
  `outcome` across fan-outs will see failures it did not see before.
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

## [0.8.0] 2026-09-06

Feature release: a chart can now report that its own run failed, and the
Ecto adapter gains room to move on large and on non-Postgres hosts. A
top-level `<final>` whose `<donedata>` sets `run_status` to `"failed"`
persists the run as `:failed` so `:first_error` settlement fires (the
ADR-0008 amendment, accepted). V04 of the DDL rebuilds V03's `metadata`
GIN index with `CREATE INDEX CONCURRENTLY` - `@current_version` is now 4,
and a host runs V04 as a migration of its own carrying
`@disable_ddl_transaction true` and `@disable_migration_lock true`. A host
that is not on Postgres has a documented opt-out: decline `lock_run/3`
with its own `serialization:` strategy and run the conformance suite with
`--exclude postgres`. And `Migrations.down/1` takes `from:`, the ceiling a
capped migration needs to roll all the way back.

### Added

- A chart can now fail its own run: settling in a top-level `<final>` whose
  `<donedata>` carries `statifier_persistence:run_status` set to `"failed"`
  persists the run as `:failed` with the `failure` string `"failed_final"`,
  so a `:first_error` fan-out cancels the failed child's siblings with no
  host-side translation.
- `docs/non-postgres-backends.md`: the supported way to run the Ecto adapter
  on a backend that is not Postgres - decline `lock_run/3` with your own
  `serialization:` strategy, what declining costs, and how to verify it.
- `StatifierPersistence.Ecto.Migrations.down/1` takes `from:`, the version it
  starts rolling back from (default: the newest this package knows), so a
  migration capped with `up(version: 2)` caps its rollback with
  `down(from: 2)`.
- V04 of the Ecto DDL rebuilds V03's `metadata` GIN index with `CREATE INDEX
  CONCURRENTLY`, so a host with a large runs table gets the index without the
  `SHARE` lock a plain build holds. Give it a migration of its own carrying
  `@disable_ddl_transaction true` and `@disable_migration_lock true` - Ecto
  reads those from your module, not from the helper - and call
  `StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 4)`.
  Called from an ordinary transactional migration it leaves V03's index in
  place instead of raising, warning when the runs table already holds rows.
  It is a no-op off `Ecto.Adapters.Postgres`, where V03 creates no index.

### Changed

- The conformance suite tags its four Postgres-only cases `@tag :postgres` -
  the two `lock_run/3` cases and the two metadata-listing cases - so a host
  running `Storage.Ecto` on another Ecto backend runs it green with
  `mix test --exclude postgres` instead of forking the suite.

### Fixed

- `mix ecto.rollback --all` no longer fails for a host that caps one
  migration and takes a later version in another: without a ceiling every
  `down/1` started at the newest version, so the capped migration rolled the
  later one's versions back a second time and failed on DDL that was already
  gone. Cap the rollback with `from:` as above.

## [0.7.2] 2026-09-06

Patch release: a fan-out whose children settle at the same time assembles
with every child's donedata present. A settlement used to read a sibling's
status as terminal while that sibling's answer was still in flight, and
assembled a completed child with a `nil` donedata; a settlement now records
its own answer under the parent's exclusion and waits for every child's
recorded answer, not only for every child's terminal status.

### Fixed

- A fan-out invocation whose children settle concurrently no longer answers with
  a `nil` donedata for a child that completed: a settlement waits for every
  child's answer to be recorded, not only for every child's status to be
  terminal, and records its own answer under the parent's exclusion.

## [0.7.1] 2026-09-05

Patch release: hosts that are not on Postgres can apply the package DDL.
V03 creates its `metadata` GIN index only on Postgres, and the Ecto
adapter now answers `supports_metadata?/1` by adapter, so a store that
could not settle a durable subchart or a fan-out is refused at open
rather than crashing partway through.

### Fixed

- V03 of the Ecto migration helper is adapter-aware: the `metadata` GIN
  `jsonb_path_ops` index is created (and dropped) only when the
  migration's repo runs on `Ecto.Adapters.Postgres`. On any other adapter
  it is skipped and the migration runs to completion, so a host on
  another backend can apply the package DDL at all - in 0.7.0 the index
  raised, the whole migration rolled back, and the `outcome_blob` column
  went with it. The column itself is still created on every adapter, and
  `StatifierPersistence.Storage.Ecto.supports_run_outcome?/1` is still
  true everywhere.
- `StatifierPersistence.Storage.Ecto.supports_metadata?/1` now answers
  `false` off Postgres, because both metadata queries the adapter issues
  are `jsonb` containment SQL. `StatifierPersistence.Storage`'s
  `child_listing_supported?/1` and `run_states_supported?/1` consult it,
  so a durable subchart or a fan-out over such a store is refused at open
  (`:child_listing_unsupported`) rather than started and left with
  children nothing could settle. Behavior on Postgres is unchanged.

## [0.7.0] 2026-09-05

Feature release: a scheduler can start a Tier A fan-out through a public
door, and the N children settle once as a dense, index-ordered list instead
of each answering the parent. Hosts on the Ecto adapter run a new V03
migration.

### Added

- `StatifierPersistence.Driver.start_child_at/6`: the public
  start-with-index door a scheduler drives a Tier A fan-out through.
  Starts child `i` of `N` for a parent's `<invoke>`, records the count and
  the aggregation policy (`:all` or `:first_error`) on the child's
  linkage, and is idempotent on the derived child run id, so a
  re-delivered start adopts rather than duplicating. Refuses at open on a
  store that could not settle the invocation afterwards.
- `StatifierPersistence.Run.Linkage.new/6`
 and `fan_out?/1`: a child's
  linkage can now carry its invocation's `child_count` and aggregation
  policy (`:all` or `:first_error`), which is what marks it as one of a
  fan-out's N rather than an ordinary durable subchart.

### Changed

- The storage-adapter `run_record` gains a nullable `outcome_blob`: a
  run's own answer, written once when it reaches a terminal status
  through `StatifierPersistence.Storage.update_run_status/4`'s new
  `outcome_blob:` option. `update_run/2` carries a stored payload forward
  when the record it is given carries none, so an ordinary step never
  erases one. Adapters gain two optional callbacks alongside it -
  `supports_run_outcome?/1` and `list_run_states_by_metadata/2`, the
  indexed status projection - and an adapter that exports neither is
  conformant unchanged.
- The Ecto adapter's V03 migration adds the `outcome_blob` column and a
  GIN `jsonb_path_ops` index on `metadata`. A host already on V02 picks
  it up with `StatifierPersistence.Ecto.Migrations.up(for: MyApp, from: 3)`.
  Run it before deploying 0.7.0, and read the README's "Upgrading to V03
  before deploying 0.7.0" first: the index build is a plain
  `CREATE INDEX` that blocks writes to the runs table for the length of
  the build.
- `StatifierPersistence.Driver` takes a `child_canceller:` option: how a
  `:first_error` settlement asks the scheduler to cancel the start jobs of
  a fan-out's not-yet-started children, which have no run record for the
  cascade to reach.
- A fan-out child's completion now settles instead of answering its
  parent's door: its answer is stored on its own run record, and only the
  settlement that finds all N indices terminal assembles the dense,
  index-ordered list and answers the invocation once.
  `StatifierPersistence.Driver.answer_parent/3` routes a fan-out child the
  same way and returns `:ok` for it. A child with no `child_count` on its
  linkage - every child created before this release - is unaffected.

## [0.6.0] 2026-09-02

Feature release: a durably-stepped run is observable through statifier's own
session telemetry, so the OpenTelemetry bridge produces the same spans and
effect events for a durable run as for a session-hosted one.

### Added

- Durably-stepped runs now emit statifier's own `[:statifier, :session, ...]`
  telemetry with `driver: :persistence`, so `opentelemetry_statifier` produces
  the same macrostep spans and effect events for a durable run as for a
  session-hosted one, with no bridge change.

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
