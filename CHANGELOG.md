# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](https://github.com/riddler/statifier_persistence/blob/main/changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.16.0] 2026-09-24

Feature release: `use StatifierPersistence.Ecto` takes two new options,
`timestamps_position:` and `column_collations:`, so the tables V01 and V05
create can place `inserted_at` and `updated_at` right after the leading
columns and declare a collation on a package text column. The release also
reports a durable child's automatic answer to a parent whose record does not
fetch, or whose chart does not resolve, on
`[:statifier_persistence, :child, :answered]` instead of dropping it.

**Breaking for a host whose telemetry handler matches `delivery` on
`[:statifier_persistence, :child, :answered]` exhaustively**: `delivery`
has two new values, `:parent_unfetched` and `:parent_chart_unresolved`, as
Changed below lists.

Upgrading: no schema migration. Both new options default to the layout
earlier releases create, and they apply only to the tables V01 and V05
create. The `statifier` floor stays `~> 2.6`.

### Added

- `use StatifierPersistence.Ecto` takes `timestamps_position: :leading`,
  which places `inserted_at` and `updated_at` right after the leading
  columns in every table V01 and V05 create; the default, `:trailing`,
  keeps them last as before.
- `use StatifierPersistence.Ecto` takes `column_collations: [name:
  collation]`, which declares a package text column with that collation
  in every V01 or V05 `CREATE TABLE` that declares it - `execution_id:
  "C"`, for example.

### Changed

- **Breaking** for a host whose telemetry handler matches `delivery` on
  `[:statifier_persistence, :child, :answered]` exhaustively: `delivery`
  has two new values, `:parent_unfetched` and `:parent_chart_unresolved`,
  and on them `outcome` is the child's own and `failed_count` is `nil`, even
  for a fan-out. Add clauses for the two values or a catch-all.

### Fixed

- A durable child's automatic answer to a parent whose record does not
  fetch, or whose chart the `chart_resolver:` does not return, reports
  `[:statifier_persistence, :child, :answered]` with `delivery:
  :parent_unfetched` or `:parent_chart_unresolved` instead of being dropped
  with nothing emitted.

## [0.15.1] 2026-09-23

Patch release: fixes and telemetry gaps found after 0.15.0. A drive that
raises now closes its step span with a new
`[:statifier_persistence, :execution, :step, :exception]` event,
`StatifierPersistence.Executions.unpark/3` reports itself on a new
`[:statifier_persistence, :execution, :unparked]` event and on the lock
event, and `StatifierPersistence.Telemetry.events/0` returns nineteen
names. `migrate/4` and `migrate_tree/4` refuse a kept invocation whose
stored ordinal names no `<invoke>` element, and `migrate_tree/4` answers
a missing execution the same way on both shipped adapters.

Upgrading: no schema migration, and no error shape a host matches is
added or removed. The `statifier` floor stays `~> 2.6`.

### Added

- `StatifierPersistence.Executions.unpark/3` emits `[:statifier_persistence, :execution, :unparked]` (`execution_id`, `content_hash`) when it puts a `:needs_migration` execution back to `:active`, and `[:statifier_persistence, :execution, :lock]` for its wait on the execution's exclusion; `StatifierPersistence.Telemetry.events/0` returns nineteen names.
- A telemetry event, `[:statifier_persistence, :execution, :step, :exception]`, closes the step span in place of `:stop` when a drive raises, throws or exits (a host executor or event builder included), carrying `execution_id`, `entry`, `span_ref`, `kind`, and a `reason` and `stacktrace` narrowed so no raised value or call argument travels; the raise still reaches the caller unchanged. `StatifierPersistence.Telemetry.events/0` returns eighteen names.
- `StatifierPersistence.Telemetry.execution_step_exception/2`, the emitter of `[:statifier_persistence, :execution, :step, :exception]`.

### Fixed

- `StatifierPersistence.Executions.migrate_tree/4` on the Ecto adapter
  answers `{:error, :execution_not_found}` for a unit naming an execution
  that is not stored, as the in-memory adapter does, instead of
  `{:error, {:adapter, :rollback}}`. That old answer came under the
  default serialization, whose per-execution lock is a transaction; under
  a serialization strategy that opens no transaction, 0.15.0 already
  answered `{:error, :execution_not_found}`. The refusal writes nothing
  and no longer aborts a caller's own enclosing transaction.
- A raise from a host executor or event builder during a drive through `StatifierPersistence.Executions` or `StatifierPersistence.Driver` no longer leaves the `[:statifier_persistence, :execution, :step, :start]` span open with no closing event.
- `StatifierPersistence.Executions.migrate/4` and `migrate_tree/4` refuse,
  with `{:invocation_element_changed, key, target}`, a stored active
  invocation whose ordinal names no `<invoke>` element of its state when the
  plan keeps it at that ordinal, instead of carrying it onto whatever element
  the new chart holds there. Repair the stored position.

## [0.15.0] 2026-09-23

Feature release: a parent execution and the durable children it invoked
can now be moved onto newer charts together, whole or not at all.
`StatifierPersistence.Executions.migrate_tree/4` takes one plan per node,
checks every node before any is written, and re-pins every named node in
one store unit or writes nothing; under `on_failure: :park` every named
node parks instead. A moved child's linkage pin follows it to its new
chart. The release also reports, on `[:statifier_persistence, :child, :answered]`,
what a parent's door answered a durable child's automatic answer, so an
answer a parked parent refused no longer passes unnoticed.

**Breaking for a host whose migration plans `migrate/4` accepted with an
invocation left off the migrated configuration or moved onto another
`<invoke>` element, or with an illegal configuration, and for a host that
matches `t:StatifierPersistence.Executions.migration_finding/0`
exhaustively**: `StatifierPersistence.Executions.migrate/4` now refuses
those three kinds of plan under three new findings, as Changed below
lists; `migrate_tree/4` applies the same checks to every node.

Upgrading: no schema migration. The two tree migration callbacks are
optional, so a storage adapter outside this package stays conformant
without them, and `migrate_tree/4` answers
`{:error, :tree_migration_unsupported}` on it. The `statifier` floor
stays `~> 2.6`.

### Added

- `[:statifier_persistence, :child, :answered]` carries `delivery`
  (`:delivered`, `:discarded`, `:needs_migration` or `:error`), so a durable
  child's automatic answer that a parked parent refused reaches the host
  instead of passing unnoticed.
- `StatifierPersistence.Executions.migrate_tree/4` emits `[:statifier_persistence, :execution, :migrated]` once per node it re-pins, the children's before the root's, after its one store unit has returned, with the same keys `migrate/4` emits; a refused or parked tree emits it for no node.
- `StatifierPersistence.Testing.StorageConformance` gains two tree migration cases for an adapter that exports `write_tree_migration/2`: every re-pin and park in the list lands with only a moved child's linkage pin rewritten in its metadata, and a list that cannot land one write lands none.
- `StatifierPersistence.Executions.migrate_tree/4` moves a parent execution and its durable children onto newer charts together: one plan per node, every node validated before any is written, children first, all in one store unit or nothing, and under `on_failure: :park` every named node parks.
- A moved child's linkage pin is rewritten to the chart it now walks, so the old chart is no longer counted as pinned by it.
- The storage adapter behaviour gains the optional `supports_tree_migration?/1` and `write_tree_migration/2` callbacks, implemented by the in-memory and Ecto adapters; an adapter without them makes `migrate_tree/4` answer `{:error, :tree_migration_unsupported}`.
- `StatifierPersistence.Storage.tree_migration_supported?/1` and `StatifierPersistence.Storage.write_tree_migration/2`, and `t:StatifierPersistence.Storage.error/0` gains `:tree_migration_unsupported`.

### Changed

- **Breaking** for a host whose migration plans move a live invocation onto a state the migrated execution is not in, or that matches `t:StatifierPersistence.Executions.migration_finding/0` exhaustively: `StatifierPersistence.Executions.migrate/4` now refuses a plan that keeps or moves an active invocation onto a state outside the transformed configuration, answering `{:invocation_outside_configuration, {state_id, ordinal}, {to_state_id, to_ordinal}}` inside `{:migration_refused, findings}` (or parking the execution under `on_failure: :park`) with nothing else written. Before, such a plan answered `:ok`, and the invoked child outlived the parent's completion because nothing cancels an invocation on a state the parent never exits. Move the invocation onto a state the migrated configuration holds instead, and add a clause for the new finding, or a catch-all, to every `case` over the findings.
- **Breaking** for a host whose migration plans drop an active state without its whole region, or that matches `t:StatifierPersistence.Executions.migration_finding/0` exhaustively: `StatifierPersistence.Executions.migrate/4` now refuses a plan whose transformed configuration is not a legal configuration of the to chart, answering `{:illegal_configuration, state_ids}` inside `{:migration_refused, findings}` (or parking the execution under `on_failure: :park`) with nothing else written. Before, a plan that dropped the state an execution waits in answered `:ok` and left its parent compound state with no active child. Plan a configuration the to chart can hold instead - map the dropped state, or drop its whole region - and add a clause for the new finding, or a catch-all, to every `case` over the findings.
- **Breaking** for a host whose migration plans keep or move a live invocation onto an `<invoke>` element other than its own, or that matches `t:StatifierPersistence.Executions.migration_finding/0` exhaustively: `StatifierPersistence.Executions.migrate/4` now refuses a plan that keeps an active invocation at its ordinal, or moves it through `invocations`, onto a different `<invoke>` element of the to chart, answering `{:invocation_element_changed, {state_id, ordinal}, {to_state_id, to_ordinal}}` inside `{:migration_refused, findings}` (or parking the execution under `on_failure: :park`) with nothing else written. The element is the same when the source element's authored `id` is the target's, or, when the source element authors none, when the target authors none and the two elements' source text is byte-equal; position alone never is. Before, a revision that reordered or replaced a state's `<invoke>` children migrated with no finding, and the live invocation took another element's finalize and autoforward. Name each invocation's move onto its own element in the plan's `invocations`, give an unnamed `<invoke>` an `id` before editing it, and add a clause for the new finding, or a catch-all, to every `case` over the findings.

## [0.14.0] 2026-09-23

Feature release: an execution can now be moved onto another chart, on
purpose and whole. `StatifierPersistence.Migration.Plan` is the plan as
data, checked against the two machines; `StatifierPersistence.Executions.migrate/4`
applies one to a single execution and either re-pins it to the new chart
or writes nothing, refusing a plan that could strand a pending timer
unless the host supplies a pin source. A refusal can instead park the
execution in a fifth status, `:needs_migration`, until a corrected plan
or `StatifierPersistence.Executions.unpark/3` puts it back. Nothing
migrates an execution because a chart was saved or published. The release
also adds a `leading_columns:` option for host-owned columns at a fixed
position, and a create's retired-chart check that no longer reads the
chart's bytes.

**Breaking for a host that matches the execution status exhaustively**:
`:needs_migration` is a fifth value of
`t:StatifierPersistence.Storage.Adapter.execution_status/0`, and the
drained query's answer gains a sixth key; a storage adapter outside this
package must store, count and refuse on the new status, as Changed below
lists. **Breaking for a host that runs Dialyzer**: `create/4` and
`step/5` each name their own option type, so an option the called
function does not act on is reported. **Breaking for a telemetry handler
that matches the adapter-call `callback` exhaustively**: a create's
retired-chart check reports two new callback names in place of
`:fetch_chart`.

Upgrading: no schema migration - the status column has no constraint
through V07, so `:needs_migration` is a new stored string and nothing
more. Move every node to 0.14.0 before any execution is parked, since an
older node does not read the new status. `leading_columns:` defaults to
`[]` and reaches a table only as V01 or V05 creates it, so an existing
install is unchanged. The `statifier` floor stays `~> 2.6`.

### Added

- A fifth execution status, `:needs_migration`: an execution parked on the chart it was already pinned to. It is not terminal, it takes no event, `fail/4` and `cancel/3` end it as they end an `:active` one, and it pins its chart against a retirement as an `:active` one does. `StatifierPersistence.Executions.migrate/4` under `on_failure: :park` is the one thing that parks an execution.
- `StatifierPersistence.Executions.unpark/3` puts a `:needs_migration` execution back to `:active` at the position it was parked at, on its own chart, writing its status and nothing else; an `:active` execution answers `{:ok, execution}` unchanged and a terminal one is discarded.
- `StatifierPersistence.Testing.StorageConformance` gains a retirement case for a durable child's pin: an adapter that exports `retire_chart/3` and `supports_metadata?/1` must refuse to retire a chart named by a terminal child's linkage pin while that child's parent is `:active`, and keep the chart's bytes.
- `StatifierPersistence.Executions.migrate/4` moves one execution onto another chart by a `StatifierPersistence.Migration.Plan`, whole or not at all (ADR-0013): it takes the two machines in `from_machine:` and `to_machine:`, re-pins the position, content hash and identity in one write at `:active` and answers `{:ok, execution, migrated}`, or refuses with `{:error, reason}` and writes nothing. Under `on_failure: :park` a refusal of the check against the execution instead writes `:needs_migration` and answers `{:parked, reason}`. A plan that leaves unmapped or drops a state that could own a timer is refused with `{:error, {:no_pin_source, states}}` unless the call supplies `pin_sources:`, and writes nothing under either `on_failure:`.
- A telemetry event, `[:statifier_persistence, :execution, :migrated]`, once per successful migration, carrying `execution_id`, `from_content_hash`, `to_content_hash` and `dropped`; `StatifierPersistence.Telemetry.events/0` returns seventeen names.
- `StatifierPersistence.Migration`, a documentation module for the namespace: what moving an execution onto another chart is, which module holds the plan and which function applies it, and that it is not `StatifierPersistence.Ecto.Migrations`, the schema-migration helper.
- `StatifierPersistence.Telemetry.execution_migrated/1`, the emitter of `[:statifier_persistence, :execution, :migrated]`, beside the package's other documented emitters.
- `StatifierPersistence.Migration.Plan`: the plan that moves an execution from one chart to another, as data (ADR-0013). `new/1` builds one and refuses a malformed plan naming the field; `to_map/1` and `from_map/1` are its one JSON-safe encoding, string keys only; `validate/3` checks a plan against the from and to machines and answers every finding at once. `StatifierPersistence.Executions.migrate/4` applies one to an execution.
- `StatifierPersistence.Executions.migrate/4` reads pending timers through a `pin_sources:` option, a list of `StatifierPersistence.PinSource` modules asked for the one execution (ADR-0013 decision 6): a state could own a timer when a `<send>` with `delay` or `delayexpr` sits in its `onentry`, `onexit`, a transition it owns or an `<invoke>`'s `<finalize>`, and a plan that maps every such state needs no source. With no source, a plan that leaves one unmapped or drops one is refused with `{:error, {:no_pin_source, states}}`; a source that cannot answer refuses with `{:error, {:pin_source_failed, {module, reason}}}`, as `retire_chart/4` does; neither writes anything under `on_failure: :park`. A non-zero count while the plan leaves such a state unmapped is the `{:pending_timers, states, source_counts}` finding of `{:migration_refused, findings}`, which parks under `:park`; a plan that drops the state instead migrates. The send and timer counters are carried, so an id the migrated execution mints cannot collide with a surviving timer's.
- `use StatifierPersistence.Ecto` accepts `leading_columns: [name: {type, opts}]`: the migrations helper places those host-owned columns immediately after `id`, in the order given, in every table V01 and V05 create; it only places them, so a default or a `NOT NULL` belongs to a later migration of the host's own.
- Two optional `StatifierPersistence.Storage.Adapter` callbacks, `supports_retired_info?/1` and `fetch_retired_info/2`: an adapter that exports both answers whether a content hash is retired without reading the chart's bytes. `StatifierPersistence.Storage.Ecto` and `StatifierPersistence.Storage.InMemory` implement them; an adapter that does not export them stays conformant and is read through `fetch_chart/2` as before, and the conformance suite checks whichever path the adapter declares.

### Changed

- **Breaking for a host that runs Dialyzer.** `StatifierPersistence.Executions.create/4` and `step/5` now each name their own option type, `t:StatifierPersistence.Executions.create_opt/0` and `t:StatifierPersistence.Executions.step_opt/0`, instead of sharing `t:StatifierPersistence.Executions.opt/0`, so Dialyzer reports an option the called function does not act on: `routes:`, `invoke_types:`, `send_types:`, `entry:`, `invoke_id:` or `child_count:` on `create/4`, and `initialize:`, `metadata:` or `linkage:` on `step/5`. Nothing changes at runtime: none of those options changed what the call did, `invoke_id:` and `child_count:` on a create reaching only its step telemetry's metadata, as they still do, and a top-level `send_types:` on `create/4` left the execution without the host's own types for its whole life. Pass `routes:`, `invoke_types:` and `send_types:` to `create/4` inside `initialize:` instead. `t:StatifierPersistence.Executions.opt/0` remains, as the union of the two.
- **Breaking** for a host that matches `t:StatifierPersistence.Storage.Adapter.execution_status/0` exhaustively: add a clause for `:needs_migration`, or a catch-all, to every `case` over an execution's status.
- **Breaking** for a host that matches the drained query's answer as a closed map: `StatifierPersistence.Executions.executions_on/2` and `StatifierPersistence.Storage.count_executions_by_content_hash/2` answer a sixth key, `needs_migration`, and a `{:pinned, counts}` refusal carries it under `executions`.
- **Breaking** for a storage adapter outside this package that stores the status or implements `count_executions_by_content_hash/2` or `retire_chart/3`: store and read back `:needs_migration`, count it under its own key, count a durable child's pin while its parent is `:active` or `:needs_migration`, and refuse to retire a chart a `:needs_migration` execution is on, or one a durable child's pin names while its parent is `:needs_migration`, as for an `:active` one. The conformance suite checks each.
- A delivery to a `:needs_migration` execution through `StatifierPersistence.Executions.step/5` or any `StatifierPersistence.Driver` door answers `{:error, {:needs_migration, execution}}`: nothing is appended, executed or written, and retrying the delivery after the execution leaves the arm is the host's. Only `StatifierPersistence.Executions.migrate/4` under `on_failure: :park` parks an execution, so a host that never parks never sees this arm.
- A durable child's linkage pin counts toward `children`, and refuses a retirement, while its parent is `:needs_migration` as well as `:active`.
- **Breaking** for a host whose telemetry handler matches the `callback` of `[:statifier_persistence, :adapter, :call]` exhaustively: `StatifierPersistence.Storage.check_chart_retired/2`, and `StatifierPersistence.Executions.create/4` through it, report `:supports_retired_info?` and `:fetch_retired_info` in place of `:fetch_chart` on an adapter that declares the narrow read, as both bundled adapters do. A handler with no clause for the two new names raises, and `:telemetry` detaches it; add them, or a catch-all.
- `StatifierPersistence.Executions.create/4`'s check for a retired chart no longer transfers the chart's stored bytes on an adapter that declares the narrow read, so its cost stays flat as charts grow; the `[:statifier_persistence, :adapter, :call]` event for that check names `:supports_retired_info?` and `:fetch_retired_info` instead of `:fetch_chart` on such an adapter.

### Fixed

- `StatifierPersistence.PinSource.collect/3`, and `StatifierPersistence.Executions.retire_chart/4` through it, refuse a pin source that throws or exits - a `GenServer.call/3` timing out inside `pins/2` - under the reasons `{:thrown, value}` and `{:exited, reason}`, instead of letting the throw or exit escape the call; a host that matches `t:StatifierPersistence.PinSource.reason/0` exhaustively adds those two arms.

## [0.13.0] 2026-09-20

Feature release: a chart can now be retired. `StatifierPersistence.Executions.retire_chart/4`
tombstones a chart nothing still uses and refuses with every pin count when
something does, `executions_on/2` and the new `StatifierPersistence.PinSource`
behaviour answer what is still using it, both chart doors answer a retired arm
in place of a retired chart's bytes, and migration V07 adds the tombstone
columns and the content-hash index those queries need.
The release also carries the host's registered Event I/O Processor types
through the execution paths: `send_types:` on `StatifierPersistence.Executions.step/5`
and on `StatifierPersistence.Driver.new/3`, stamped onto the loaded position
beside `invoke_types:`.

Upgrading: run V07 against an existing database. An install already at V06
writes `up(for: MyApp.Persistence, from: 7)` - `from:` is inclusive, so that
call runs V07 and nothing before it - and V07 copies no data. A host that
reads charts gains one arm to handle: `StatifierPersistence.Storage.fetch_chart/2`
answers `{:error, {:chart_retired, info}}` for a hash a retirement has
tombstoned, in place of `:chart_not_found`. A host that never retires a chart
never sees it.
The `statifier` floor moves to `~> 2.6`, the first release carrying
host-registered send types.

### Added

- `StatifierPersistence.PinSource`, a behaviour a host implements so state this package cannot see - a pending timer, an address row - can report named counts against a content hash, with `collect/3` gathering each source's counts under its module name and turning a source that raises or answers malformed into `{:error, {module, reason}}` rather than a zero.
- `StatifierPersistence.Storage.check_chart_retired/2`, which answers the retired arm for a machine's own content hash without writing anything.
- `StatifierPersistence.Executions.executions_on/2` counts the executions on one content hash, per stored status.
- `StatifierPersistence.Storage.count_executions_by_content_hash/2` and `content_hash_query_supported?/1` over two new optional adapter callbacks, `count_executions_by_content_hash/2` and `supports_content_hash_query?/1`.
- Migration V07: an index on `executions(content_hash)`, the nullable `retired_at` and `retired_by` columns on `charts`, and - on Postgres - nullable `identity_blob` and `chart_blob` on `charts`.
- `StatifierPersistence.Executions.retire_chart/4` retires a chart, or refuses with every pin count when anything still uses it.
- `StatifierPersistence.Storage.retire_chart/3`, `chart_retirement_supported?/1` and `list_active_execution_ids_by_content_hash/2` over three new optional adapter callbacks, `retire_chart/3`, `supports_chart_retirement?/1` and `list_active_execution_ids_by_content_hash/2`.
- A position row on a content hash is a pin: it refuses a retirement of that chart even when no execution runs on it.
- The generated chart schema carries the `retired_at` and `retired_by` columns migration V07 adds.
- `StatifierPersistence.Storage.Adapter.pin_counts/3`, `pinned?/1` and `sources_pinned?/1`, with the `pin_counts/0`, `execution_counts/0` and `source_counts/0` types: the one shape a `retire_chart/3` refusal carries and the predicate for whether what an adapter counted is a pin, so a third-party adapter builds its refusal through them instead of inventing a second shape for one answer.
- `send_types:` on `StatifierPersistence.Executions.step/5`, the `Statifier.Send.Types.t/0` snapshot of the host's registered Event I/O Processor types, stamped onto the loaded position the way `invoke_types:` is; on `create/4` it travels inside `initialize:`.
- `send_types:` on `StatifierPersistence.Driver.new/3`, a driver-level default carried onto every step and, through `initialize:`, onto the create.

### Changed

- `StatifierPersistence.Executions.create/4` refuses a chart a retirement has tombstoned with `{:error, {:chart_retired, info}}`, before it writes an execution row or executes an effect.
- The adapter error vocabulary gains `:content_hash_query_unsupported`, the refusal for an adapter that cannot answer the content-hash count.
- `StatifierPersistence.Storage.fetch_chart/2` gains a `{:chart_retired, info}` error arm for a retired hash, carrying who retired it and when, instead of `:chart_not_found`.
- `StatifierPersistence.Storage.save_chart/3` refuses that same arm for a retired hash rather than reviving the row.
- The adapter error vocabulary gains `:chart_retirement_unsupported`, the refusal for a store whose chart blob columns are not nullable, and `{:pinned, counts}`, the refusal carrying every count.
- `StatifierPersistence.Executions.executions_on/2` answers a real `children` count: the durable-child linkage pins naming the hash whose parent execution is `:active`, in place of the zero both bundled adapters returned for that key.
- The `statifier` floor is `~> 2.6`, the first release carrying host-registered send types.

## [0.12.0] 2026-09-13

Breaking release: `run` is retired as the noun for the durable record, and
the package speaks `execution` throughout - modules, functions, callbacks,
types, error atoms, telemetry events and metadata, the durable table and its
identity column (ADR-0011). No behaviour, arity or return shape changed; only
names did, and no compatibility shim, deprecated delegate or alias module
ships.

**Breaking for storage adapters**: all seven
`StatifierPersistence.Storage.Adapter` callbacks rename, and the table under
Changed below lists every one of them - the compiler names each in turn.
Hosts also rename the `run_id:` context key, this package's `:run_*` error
atoms, the `:tables` key (`:runs` is now rejected), and any raw query naming
`statifier_runs`; telemetry handlers must move to the `:execution` prefix,
which does not dual-emit. Existing databases are migrated **in place** by the
new **V06**, which copies no data; drain in-flight durable subchart children
before upgrading.

### Changed

- **Breaking for storage adapters.** `run` is retired as the noun for the
  durable record; it is `execution` everywhere (ADR-0011). Nothing about the
  behaviour, the arities, the return shapes or the identity guard changed -
  only names. This entry is the complete list of what moved. Rename the seven
  `StatifierPersistence.Storage.Adapter` callbacks below in your adapter; the
  compiler names every one of them, and no compatibility shim, deprecated
  delegate or alias module ships.

  | Callback before | After |
  |---|---|
  | `insert_run/2` | `insert_execution/2` |
  | `fetch_run/2` | `fetch_execution/2` |
  | `update_run/2` | `update_execution/2` |
  | `lock_run/3` | `lock_execution/3` |
  | `list_runs_by_metadata/2` | `list_executions_by_metadata/2` |
  | `supports_run_outcome?/1` | `supports_execution_outcome?/1` |
  | `list_run_states_by_metadata/2` | `list_execution_states_by_metadata/2` |

  `append_input/3` and `list_inputs/2` keep their names; their `run_id()`
  parameter is now `execution_id()`.

- **Breaking for a host-supplied serialization strategy.** The second
  behaviour a host may implement renames its one callback:
  `StatifierPersistence.Serialization.with_run/3` is now `with_execution/3`,
  and the shipped `Serialization.AdapterLock.with_run/3` is now
  `AdapterLock.with_execution/3`. A host that left the strategy at its default
  implements nothing and is unaffected. The two module names are unchanged -
  they name a strategy, not the durable record.

- **Breaking, silently, for a host effect executor and a `:dispatch`
  function.** The `run_id:` key of `StatifierPersistence.Executor.context/0`
  and of `StatifierPersistence.Driver.dispatch_context/0` is now
  `execution_id:`. An implementation that pattern-matches `%{run_id: id}`
  raises at the first effect; one that reads the key by name gets `nil`.
  Rename the key in both.

- **Breaking for a host that pattern-matches this package's error atoms.**
  `:run_exists`, `:run_not_found`, `:run_outcome_unsupported`,
  `:run_states_unsupported`, `:run_position_missing` are now
  `:execution_exists`, `:execution_not_found`,
  `:execution_outcome_unsupported`, `:execution_states_unsupported`,
  `:execution_position_missing`. A `case` with no catch-all raises; one with a
  catch-all quietly reclassifies a known refusal.

- **Breaking for anything subscribed to this package's telemetry.** The event
  family is now `[:statifier_persistence, :execution, :step, :start | :stop]`,
  `[:statifier_persistence, :execution, :lock]` and
  `[:statifier_persistence, :execution, :created | :terminated | :discarded]`.
  There is no dual emit: a handler attached to the old `:run` names goes
  silent with no error, so grep your handlers for the old prefix as part of
  the upgrade. `opentelemetry_statifier` 0.6.0 moves in lockstep.

- Telemetry metadata keys `run_id`, `parent_run_id` and `child_run_id` are now
  `execution_id`, `parent_execution_id` and `child_execution_id` on every
  event that carries them, including the events whose own names did not
  change (`[:statifier_persistence, :adapter, :call]`, `:identity, :refused`,
  `:effect, :failed`, `:drive, :turns_exhausted` and the six
  `[:statifier_persistence, :child, ...]` events).

- Two documented telemetry metadata *values* rename with them: `stage: :run`
  becomes `stage: :execution` on `[:statifier_persistence, :identity,
  :refused]`, and `reason: :terminal_run` becomes `reason:
  :terminal_execution` on `[:statifier_persistence, :execution, :discarded]`.

- The six documented `StatifierPersistence.Telemetry` emitters rename with
  their events: `run_step_start/3`, `run_step_stop/2`, `run_lock/2`,
  `run_created/1`, `run_terminated/1` and `run_discarded/1` are now
  `execution_step_start/3`, `execution_step_stop/2`, `execution_lock/2`,
  `execution_created/1`, `execution_terminated/1` and
  `execution_discarded/1`. The other ten emitters keep their names.

- Modules: `StatifierPersistence.Run` is now `StatifierPersistence.Execution`
  (struct field `:run_id` is now `:execution_id`), `StatifierPersistence.Runs`
  is now `StatifierPersistence.Executions`, and
  `StatifierPersistence.Run.Linkage` is now
  `StatifierPersistence.Execution.Linkage`, whose `child_run_id/3` is now
  `child_execution_id/3`. The lifecycle doors keep their own names and
  arities: `Executions.create/4`, `step/5`, `fail/4`, `cancel/3`,
  `cascade_cancel/3` and `inputs/2`.

- `StatifierPersistence.Storage` renames nine functions, arities unchanged:
  `insert_run/5`, `update_run/5`, `update_run_status/4`, `fetch_run/2`,
  `run_outcome_supported?/1`, `run_states_supported?/1`,
  `list_run_states_by_metadata/2`, `list_runs_by_metadata/2` and
  `load_run_position/3` become `insert_execution/5`, `update_execution/5`,
  `update_execution_status/4`, `fetch_execution/2`,
  `execution_outcome_supported?/1`, `execution_states_supported?/1`,
  `list_execution_states_by_metadata/2`, `list_executions_by_metadata/2` and
  `load_execution_position/3`.

- Types: `Storage.Adapter.run_id/0`, `run_status/0`, `run_record/0` and
  `run_state/0` are now `execution_id/0`, `execution_status/0`,
  `execution_record/0` and `execution_state/0`, and the `run_id:` key inside
  `execution_record/0`, `execution_state/0`, `input_record/0` and
  `Storage.input/0` is now `execution_id:`. `Runs.run_id/0` is now
  `Executions.execution_id/0`, and `Storage.run_write_opt/0` is now
  `Storage.execution_write_opt/0`.

- The reserved child-linkage metadata key written into a child's `metadata`
  map is now `"parent_execution_id"`, and `Execution.Linkage`'s struct field
  is `:parent_execution_id`. A child written by 0.11.x carries the old key;
  re-key it or let those executions finish under 0.11.x.

- `use StatifierPersistence.Ecto` now generates `MyApp.Persistence.Execution`
  instead of `MyApp.Persistence.Run`, and the executions and inputs schemas
  expose the field as `execution_id` instead of `run_id`. A host naming the
  module or the field in its own queries renames both.

- New surrogate ids for that table carry the `exec_` prefix instead of
  `run_`. Existing rows keep the ids they have - nothing rewrites them - so
  both spellings coexist permanently on an upgraded install. Nothing in this
  package parses a prefix and no host should; one that does must accept both.

- The reserved `<donedata>` key a chart writes to fail itself is now
  `statifier_persistence:execution_status`.

- **Breaking for hosts.** The durable table is now `statifier_executions`,
  and its identity column - in that table and in `statifier_inputs` - is now
  `execution_id` (ADR-0011 decision 3). A new migration, **V06**, makes the
  move on an existing database: it renames the table, both columns, both
  unique indexes and the `metadata` GIN index **in place**, copying no data,
  and it is a no-op on a database created at 0.12.0 or later. Run
  `StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 6)`
  from an ordinary host migration; a fresh install gets the new names from
  V01 and needs nothing extra. That one-line upgrade is for an install
  already at V05: one capped below V04, which still owes V02, V03 or V04,
  runs `up(for: MyApp.Persistence, from: 6, version: 6)` **first** and
  then `up(for: MyApp.Persistence, from: <its cap + 1>, version: 5)` -
  `from: 2` for a host capped at V01, `from: 3` at V02, `from: 4` at V03 -
  because V02-V04 alter the executions table, which on such a database
  carries that name only once V06 has renamed it; the migration's `down`
  mirrors the two calls in reverse,
  `down(for: MyApp.Persistence, from: 5, version: <its cap + 1>)` and then
  `down(for: MyApp.Persistence, from: 6, version: 6)`. Rename the table in
  any raw query, view,
  materialized view, hand-written Ecto schema or dashboard of your own that
  names it - it is `statifier_executions` on both paths. "In place" is exact
  for the table and the columns on every backend; off Postgres, which has no
  `ALTER INDEX ... RENAME TO`, the two unique indexes are dropped and
  declared again under their new names instead, which still copies no data.

- **Breaking for a host that overrides table names.** The `:tables` key for
  this table is now `:executions`; `:runs` is rejected with
  `ArgumentError`, and no alias ships for a release. Rename the key in your
  `use StatifierPersistence.Ecto` options. A `:tables` override's *value* is
  untouched: V06 renames the columns and indexes under whatever name you
  gave, and the table keeps that name.

- **Rolling back drops the tables under their new names.** V01-V05 are
  rewritten to the new noun and drop the tables under those names, so
  `StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence)`
  still removes everything this package owns, on a fresh install and on an
  upgraded one alike. What it is not is a downgrade: to run 0.11.x again,
  restore a backup or migrate up with 0.11.x's own migrations.

- **An in-flight durable subchart child does not survive the upgrade.** A
  child created under 0.11.x carries its parent link in `metadata` under the
  pre-0.12.0 key, and V06 renames no stored value - it is a catalog
  operation and copies no data. `Execution.Linkage.from_metadata/1`
  therefore answers `:no_linkage` for such a child, and its completion no
  longer settles its parent's fan-out. **Drain your in-flight children
  before upgrading**: let every durable subchart child reach a terminal
  status under 0.11.x, then upgrade. Children created at 0.12.0 or later are
  unaffected.

- The migration helper now knows six versions:
  `StatifierPersistence.Ecto.Migrations.expected_version/0` answers `6`.

- The surrogate-key table map renames with the table key:
  `t:StatifierPersistence.Ecto.KeyGenerator.table/0` is now
  `:charts | :positions | :executions | :inputs`, and the shipped UXID
  generator's prefix for that table is `"exec"` (it was already `"exec"` in
  0.11.x under the old key). A host with its own `Ecto.KeyGenerator`
  implementation renames the atom it matches on.

- V06's `down/1` is a no-op, so a rollback never renames the durable table
  back to its pre-0.12.0 name. V01-V05 drop the tables under the execution
  names on every install this package can reach at 0.12.0, and returning to
  the retired names would only be meaningful under a downgrade to
  pre-0.12.0 code, which is unsupported - restore from a backup instead.
  This is what makes `mix ecto.rollback --all` work for a host that writes
  one migration per package version: a conditional rename would run in its
  own rollback step and the steps behind it would then name objects that
  are no longer there.

### Deprecated

- The pre-0.12.0 `<donedata>` key,
  `statifier_persistence:run_status`, is still **read** in this release and is
  **dropped in 0.13.0**: where both are present the new key wins, and reading
  the old one logs one deprecation line at `:debug` naming the new key. Update
  your charts' `<param name="...">` before 0.13.0. It is the only
  transitional reader this rename ships.

## [0.11.0] 2026-09-08

Feature release: a durably stepped run can now report itself as it goes.
`StatifierPersistence.Driver.new/3` takes an `after_step:` callback, fired
after every step the driver takes on a caller's behalf - a durable subchart
child's own steps and the parent's step on the answer path alike - so a host
can trace, project or checkpoint from one seam instead of wrapping each entry
point. Alongside it, `StatifierPersistence.Testing.StorageConformance` no
longer writes from a `setup`, so an adapter's own `setup` runs first.

### Added

- `StatifierPersistence.Driver.new/3` takes `after_step:`, a
  `(run_id, machine_state, effects -> any)` callback fired after every step
  the driver takes on a caller's behalf - a durable subchart child's own
  steps and the parent's step on the answer path included, each under the id
  of the run that was stepped, with the whole effect list that step produced.
  It defaults to `nil` and may be overridden per call on `create/3`,
  `send_event/4`, `done_invocation/5` and `failed_invocation/5`.

### Fixed

- `StatifierPersistence.Testing.StorageConformance` no longer registers a
  `setup` that writes: the input-log cases build their fixture run inside
  the case body, so a host's own `setup` - even one written below the
  `use` - is no longer preceded by a write. The moduledoc states the
  ordering contract a host binds against.

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
