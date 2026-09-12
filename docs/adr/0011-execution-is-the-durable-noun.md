# ADR-0011: `execution` is the durable noun: the modules, the types, the adapter callbacks, the tables, the V06 rename, the two donedata keys, and the telemetry prefix

Status: proposed (2026-09-12, sp-n55; campaign SF041, RQ-SF041-7/-8/-9 ruled by
the operator the same day; epic sp-hnp. sp-op4 and sp-j2y build it, sp-478 and
sp-pcw carry the pointer Notes, and sp-5nv flips this record once the code and
the migration are on `main`)

## Context

`run` is the word this package has used since ADR-0004 for the durable thing it
owns: a stored, locked, resumable instance of a chart. It is also one of the
most overloaded words a host application has. A host that embeds this package
already has ingest runs, CI runs, job runs and report runs of its own, and ends
up legislating a per-host carve-out rule - "run means the engine's execution,
our runs mean something else" - which has to be restated in every new domain the
host grows into. The collision is in the name, not in the mechanism, so it is
cheaper to change the name once here than to manage it in every host forever.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`70d86bd`**
(`70d86bdccd66c574198714b51080660c123f583d`), read 2026-09-12. Every code cite in
this record carries that SHA and an anchor beside its line number, because line
numbers move and anchors do not.

What speaks `run` today, in full:

- **The modules.** `StatifierPersistence.Run`
  (`lib/statifier_persistence/run.ex:1`, `defmodule StatifierPersistence.Run`,
  @70d86bd), whose struct is
  `defstruct [:run_id, :status, :content_hash, :failure, :donedata]`
  (`run.ex:13`, @70d86bd); `StatifierPersistence.Runs`
  (`lib/statifier_persistence/runs.ex:1`, `defmodule StatifierPersistence.Runs`,
  @70d86bd); `StatifierPersistence.Run.Linkage`
  (`lib/statifier_persistence/run/linkage.ex:1`,
  `defmodule StatifierPersistence.Run.Linkage`, @70d86bd).
- **The lifecycle doors.** `Runs.create/4` (`runs.ex:298`,
  `def create(%Storage{} = store, run_id, %Machine{} = machine, opts)`,
  @70d86bd), `Runs.step/5` (`runs.ex:406`, `def step(%Storage{} = store,
  run_id, %Machine{} = machine, event, opts)`, @70d86bd), `Runs.fail/4`
  (`runs.ex:490`, @70d86bd), `Runs.cancel/3` (`runs.ex:558`, @70d86bd),
  `Runs.cascade_cancel/3` (`runs.ex:634`, @70d86bd) and `Runs.inputs/2`
  (`runs.ex:683`, @70d86bd).
- **The donedata key.** `@run_status_key "statifier_persistence:run_status"`
  (`runs.ex:1617`, @70d86bd), documented in the moduledoc heading about a
  failure-classed final (`runs.ex:33` and the worked `<param
  name="statifier_persistence:run_status" expr="'failed'"/>` at `runs.ex:37`,
  @70d86bd). It is the one place a *chart author* writes this package's
  vocabulary, so it is the only surface here that is not purely an API name.
- **The linkage metadata key.** `"parent_run_id"`, both as the struct field
  (`run/linkage.ex:75`, `@enforce_keys [:parent_run_id, :invoke_id,
  :child_index, :content_hash]`, @70d86bd) and as the reserved string key
  written into a child's metadata map (`run/linkage.ex:181`,
  `"parent_run_id" => linkage.parent_run_id`, @70d86bd).
- **The adapter contract.** The four types `run_id/0`
  (`lib/statifier_persistence/storage/adapter.ex:54`, `@type run_id ::
  String.t()`, @70d86bd), `run_status/0` (`adapter.ex:62`, `@type run_status ::
  :active | :completed | :failed | :cancelled`, @70d86bd), `run_record/0`
  (`adapter.ex:100`, @70d86bd) and `run_state/0` (`adapter.ex:122`, @70d86bd);
  and the seven callbacks that name a run: `insert_run/2` (`adapter.ex:295`),
  `fetch_run/2` (`adapter.ex:309`), `update_run/2` (`adapter.ex:344`),
  `lock_run/3` (`adapter.ex:384`), `list_runs_by_metadata/2` (`adapter.ex:422`),
  `supports_run_outcome?/1` (`adapter.ex:442`) and
  `list_run_states_by_metadata/2` (`adapter.ex:466`), all @70d86bd.
- **The guarded facade.** `Storage.insert_run/5` (`storage.ex:304`, @70d86bd),
  `Storage.update_run/5` (`storage.ex:354`), `Storage.update_run_status/4`
  (`storage.ex:401`), `Storage.fetch_run/2` (`storage.ex:420`),
  `Storage.run_outcome_supported?/1` (`storage.ex:486`),
  `Storage.run_states_supported?/1` (`storage.ex:506`),
  `Storage.list_run_states_by_metadata/2` (`storage.ex:529`),
  `Storage.list_runs_by_metadata/2` (`storage.ex:551`) and
  `Storage.load_run_position/3` (`storage.ex:710`), all @70d86bd.
- **The lock.** The Ecto adapter's per-run exclusion is
  `repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
  [run_id])` (`lib/statifier_persistence/storage/ecto.ex:570`, @70d86bd).
- **The schema.** `@table_keys [:charts, :positions, :runs, :inputs]`
  (`lib/statifier_persistence/ecto/config.ex:46`, @70d86bd), resolved against
  the default `:table_prefix` of `"statifier_"` (`ecto/config.ex:72`, @70d86bd)
  by `Config.table/2` (`ecto/config.ex:91`, `config.table_prefix <>
  Atom.to_string(table)`, @70d86bd), so the shipped names are
  `statifier_runs` and `statifier_inputs`. The `runs` table and its unique
  index are V01 (`ecto/migrations/v01.ex:64-80`, `runs = Config.table(config,
  :runs)` through `create(unique_index(runs, [:run_id], prefix:
  config.prefix))`, @70d86bd); the `metadata` GIN index is V03
  (`ecto/migrations/v03.ex:94`, `index(runs, ["metadata jsonb_path_ops"]`,
  @70d86bd) as rebuilt by V04 (`ecto/migrations/v04.ex:176`, @70d86bd); the
  input log's `run_id` column and its unique index are V05
  (`ecto/migrations/v05.ex:51` and `:60`, `create(unique_index(inputs,
  [:run_id, :seq], prefix: config.prefix))`, @70d86bd).
- **The telemetry names.** The `[:statifier_persistence, :run, ...]` family and
  the `run_id` / `parent_run_id` / `child_run_id` metadata keys, declared as
  module attributes at `lib/statifier_persistence/telemetry.ex:160-175`
  (`@run_step_start [:statifier_persistence, :run, :step, :start]` at `:160`
  through `@child_cascade_cancelled` at `:175`, @70d86bd) and tabulated in the
  moduledoc from `telemetry.ex:58` (@70d86bd).
- **The records.** ADR-0004, ADR-0006, ADR-0008, ADR-0009 and ADR-0010 all use
  `run` as a defined term, ADR-0002 names the "runs vocabulary" in its own
  title, and ADR-0002 decision 5 is what makes the table name configurable at
  all.

### What does not exist, despite earlier drafts saying so

The epic `sp-hnp`'s original scope paragraph named three things this package
does not have. They are recorded here so a reader of that paragraph is not
misled: there is **no `run_events` table** (the four table keys are
`:charts`, `:positions`, `:runs`, `:inputs`; `ecto/config.ex:46`, @70d86bd),
and there are **no `create_run/load_run` functions** (the doors are
`Runs.create/4` and `Runs.step/5`, and the load is
`Storage.load_run_position/3`). `sp-hnp`'s dated 2026-09-12 note supersedes
that paragraph and this record rests on the note.

### What bounds the answer

- **Table names are already host-configurable.** ADR-0002 decision 5 makes the
  physical names a host's choice through `:tables` and `:table_prefix`, so the
  rename decided here changes the *default* names and the *key* that selects
  them, not a name a host cannot move.
- **The identity guard is untouched.** ADR-0003 puts the guard above every
  adapter; it is keyed on the chart's identity, never on the durable record's
  name.
- **Blobs stay blobs.** ADR-0006's `metadata` map and ADR-0010's `input_blob`
  are opaque to this layer. Nothing in this record reaches inside a stored
  value, with the single exception of the reserved linkage keys ADR-0008
  defines, which this package writes itself.
- **Two consumers read our telemetry names.** `opentelemetry_statifier`
  subscribes to the `[:statifier_persistence, ...]` family, and
  `statifier_oban` carries a `parent_run_id` argument. They are separate
  packages with separate releases, which is why the ordering in decision 5
  matters.

## Decision

### 1. A stored, locked, resumed instance of a chart is an **execution**, and `run` leaves the public surface

The durable thing this package owns is an **execution**: a chart, a position, a
status and an outcome, guarded by the identity check and serialized by the
per-execution exclusion. `run` is retired as a term of art here. It does not
survive as a documented synonym, a `@doc` aside or a deprecated delegate; where
this record's names replace an old name, the old name is gone from the public
surface in the release that carries the rename.

The word `run` may still appear in this package's prose as an ordinary English
verb ("the loop runs", "a migration runs"). What it may not be again is a noun
naming the durable record.

### 2. The names

The table below is the complete list of public names this record changes. The
left column is today's name at `70d86bd` with today's arity, read off the
definition; the right column is the name after sp-op4. Arity is part of a name,
so a row whose arity differs on the two sides would be a change of shape and not
a rename - there is no such row.

**Modules**

| Today (@70d86bd) | After |
|---|---|
| `StatifierPersistence.Run` (`run.ex:1`) | `StatifierPersistence.Execution` |
| `StatifierPersistence.Runs` (`runs.ex:1`) | `StatifierPersistence.Executions` |
| `StatifierPersistence.Run.Linkage` (`run/linkage.ex:1`) | `StatifierPersistence.Execution.Linkage` |

**Types on `StatifierPersistence.Storage.Adapter`**

| Today (@70d86bd) | After |
|---|---|
| `run_id/0` (`adapter.ex:54`) | `execution_id/0` |
| `run_status/0` (`adapter.ex:62`) | `execution_status/0` |
| `run_record/0` (`adapter.ex:100`) | `execution_record/0` |
| `run_state/0` (`adapter.ex:122`) | `execution_state/0` |

The `run_id:` key inside `run_record/0` and `run_state/0` becomes
`execution_id:` with them.

**`Storage.Adapter` callbacks**

| Today (@70d86bd) | After |
|---|---|
| `insert_run/2` (`adapter.ex:295`) | `insert_execution/2` |
| `fetch_run/2` (`adapter.ex:309`) | `fetch_execution/2` |
| `update_run/2` (`adapter.ex:344`) | `update_execution/2` |
| `lock_run/3` (`adapter.ex:384`) | `lock_execution/3` |
| `list_runs_by_metadata/2` (`adapter.ex:422`) | `list_executions_by_metadata/2` |
| `supports_run_outcome?/1` (`adapter.ex:442`) | `supports_execution_outcome?/1` |
| `list_run_states_by_metadata/2` (`adapter.ex:466`) | `list_execution_states_by_metadata/2` |

`append_input/3` (`adapter.ex:513`) and `list_inputs/2` (`adapter.ex:526`) keep
their names; their `run_id()` parameter becomes `execution_id()` by decision 2's
type row.

**`StatifierPersistence.Storage`**

| Today (@70d86bd) | After |
|---|---|
| `insert_run/5` (`storage.ex:304`) | `insert_execution/5` |
| `update_run/5` (`storage.ex:354`) | `update_execution/5` |
| `update_run_status/4` (`storage.ex:401`) | `update_execution_status/4` |
| `fetch_run/2` (`storage.ex:420`) | `fetch_execution/2` |
| `run_outcome_supported?/1` (`storage.ex:486`) | `execution_outcome_supported?/1` |
| `run_states_supported?/1` (`storage.ex:506`) | `execution_states_supported?/1` |
| `list_run_states_by_metadata/2` (`storage.ex:529`) | `list_execution_states_by_metadata/2` |
| `list_runs_by_metadata/2` (`storage.ex:551`) | `list_executions_by_metadata/2` |
| `load_run_position/3` (`storage.ex:710`) | `load_execution_position/3` |

**Struct and metadata keys**

| Today (@70d86bd) | After |
|---|---|
| `%Run{run_id: ...}` (`run.ex:13`) | `%Execution{execution_id: ...}` |
| `Linkage`'s `:parent_run_id` field (`run/linkage.ex:75`) | `:parent_execution_id` |
| the reserved metadata string `"parent_run_id"` (`run/linkage.ex:181`) | `"parent_execution_id"` |

**Telemetry**

| Today (@70d86bd) | After |
|---|---|
| `[:statifier_persistence, :run, :step, :start \| :stop]` (`telemetry.ex:160-161`) | `[:statifier_persistence, :execution, :step, :start \| :stop]` |
| `[:statifier_persistence, :run, :lock]` (`telemetry.ex:162`) | `[:statifier_persistence, :execution, :lock]` |
| `[:statifier_persistence, :run, :created \| :terminated \| :discarded]` (`telemetry.ex:165-167`) | `[:statifier_persistence, :execution, :created \| :terminated \| :discarded]` |
| metadata `run_id` | `execution_id` |
| metadata `parent_run_id`, `child_run_id` | `parent_execution_id`, `child_execution_id` |

The `[:statifier_persistence, :adapter, :call]`,
`[:statifier_persistence, :identity, :refused]`,
`[:statifier_persistence, :effect, :failed]`,
`[:statifier_persistence, :drive, :turns_exhausted]` and the six
`[:statifier_persistence, :child, ...]` event names keep their own second
segment; only their `run_id`-shaped metadata keys move, per the rows above.

Private functions, local variables, parameter names, test names and doc prose
follow the same rename without being enumerated here: the table fixes the
*public* surface, and the rest is consistency work sp-op4 does in the same pass.

### 3. The tables, the columns, the indexes, the V06 migration, and the `Config` key

- The `:runs` table key becomes `:executions`, so `@table_keys`
  (`ecto/config.ex:46`, @70d86bd) becomes
  `[:charts, :positions, :executions, :inputs]` and the shipped default name
  becomes **`statifier_executions`**.
- The `:inputs` key and the table name `statifier_inputs` are **unchanged**.
- The `run_id` column becomes `execution_id` in **both** tables: the executions
  table (V01's `add(:run_id, :text, null: false)`, `v01.ex:68`, @70d86bd) and
  the input log (V05's `add(:run_id, :text, null: false)`, `v05.ex:51`,
  @70d86bd).
- **Migration V06** performs the rename **in place**: the table, the two
  `run_id` columns, V01's unique index on `(run_id)`, V05's unique index on
  `(run_id, seq)` and V03/V04's `metadata` GIN index (whose generated name is
  derived from the table name, `v03.ex:126` and `v04.ex:191`, @70d86bd). It
  copies no data - a rename is a catalog operation and this record forbids any
  variant that reads or writes rows. It ships a `down/0` that restores every old
  name, and the conformance suite exercises both directions.
- A host that already set `:tables` or `:table_prefix` explicitly keeps whatever
  it set; V06 renames from the resolved old name to the resolved new name, which
  is what makes it correct under ADR-0002 decision 5.
- The `Config` option key becomes `:executions`. `:runs` is **accepted as an
  alias for one release**: supplying it resolves the executions table and logs a
  deprecation line naming `:executions`. It is removed in the release named in
  decision 4.
- The Postgres advisory lock keeps its shape; only the variable it hashes is
  renamed (`storage/ecto.ex:570`, @70d86bd). The lock's identity is the hash of
  the id string, so a rename of the variable changes no lock value and no
  running system's exclusion.

### 4. The donedata key becomes `statifier_persistence:execution_status`, and both keys are read for one release

`statifier_persistence:run_status` (`runs.ex:1617`, @70d86bd) is written by
*chart authors*, not by hosts, so it cannot break in the same breath as an API
name: an existing chart's `<param>` is data already committed to a repository
somewhere, and it may be running.

- The emitted and documented key becomes
  **`statifier_persistence:execution_status`**.
- `Executions` reads **both** keys for one release: the new key wins where both
  are present, and reading the old key logs a deprecation line naming the new
  one.
- The old key is **dropped in `0.13.0`**. This package is at `0.11.0`
  (`mix.exs:4`, `@version "0.11.0"`, @70d86bd) and the rename ships in `0.12.0`
  (sp-8b7), so "one release" is `0.12.0`, and `0.13.0` is the first release that
  reads only `statifier_persistence:execution_status`. The same release removes
  decision 3's `:runs` `Config` alias.
- The value vocabulary (`"failed"`) is unchanged, and the failure-classed-final
  mechanism ADR-0004 and `runs.ex:33-37` (@70d86bd) describe is unchanged. Only
  the key name moves.

### 5. Telemetry emits the new prefix only, and `opentelemetry_statifier` moves in lockstep

- This package emits `[:statifier_persistence, :execution, ...]` and **nothing
  else**. There is no dual emit, no transitional double-publish and no
  configuration knob that restores the old names. A handler attached to the old
  event names stops receiving events in `0.12.0`, and the changelog says so.
- The reason is ADR-0009 decision 8: this package owns the names and amends the
  contract in place. A dual emit would make every event arrive twice for any
  consumer that subscribed to both, would double the cost on the hottest path,
  and would have to be removed later anyway - paying the break twice rather than
  once.
- `opentelemetry_statifier` moves in the same wave, not after it: its span name
  and its subscriptions are rewritten and it is released immediately after this
  package (`sp 0.12.0` then `ots 0.6.0`). A host that upgrades one without the
  other loses spans until it upgrades the second; the changelog of each names the
  other.

### 6. No `Storage.Adapter` callback shim: the behaviour breaks, and the changelog says what to do

The renamed callbacks of decision 2 are a hard break for any out-of-tree storage
adapter. This record deliberately ships no compatibility layer: no
`defoverridable` bridge, no `__using__` macro that defines the old names, no
`Code.ensure_loaded?`-style dispatch that tries the new callback and falls back
to the old one.

- A behaviour with two accepted spellings is a behaviour with no contract: the
  `@callback` list is what `@behaviour` checks, and a shim makes the compiler
  stop telling an adapter author that they have not migrated.
- The break is mechanical and total. An adapter implements seven renamed
  callbacks and changes no logic; the compiler names every one of them.
- The `0.12.0` changelog fragment therefore carries **Breaking for storage
  adapters** in bold and says what to do about it - the rename table of decision
  2 and the fact that no behaviour beyond the names changed
  (`changelog.d/README.md:64`, "say what to do about it"). sp-op4 and sp-j2y write that
  fragment; this record does not.

### 7. What this record is not

- **Not a change to the identity guard.** ADR-0003's guard runs above every
  adapter on every load, keyed on chart identity. Nothing here touches when it
  runs, what it compares, or what it refuses with.
- **Not a change to the input log's shape.** ADR-0010's two optional callbacks,
  the verbatim event, the door stamp, the dense ordinal, the per-log cap and the
  closing marker are all unchanged. The `inputs` table keeps its name; only its
  `run_id` column is renamed, by decision 3.
- **Not a change to child linkage semantics.** ADR-0008's mandatory
  chart-identity pin, the `:pending` dispatch, the two completion doors, the
  cascading cancel that retains, the cycle refusal and the fan-out policies are
  unchanged. The reserved key `"parent_run_id"` is renamed by decision 2 and
  nothing about what it means moves.
- **Not a change to ADR-0006's metadata contract.** The map stays opaque, host
  identities only, never personal data, with the same refusal at open.
- **Not a change to anything upstream.** `statifier-ex` renames no module and no
  function for this; its `lib/` has no `run` noun to move. Its documentation
  examples are corrected, and that is all.
- **Not a rename of the blocks editor's "run".** `statifier_blocks` uses "run"
  for fixture replay and keeps the word; only the donedata key of decision 4
  moves there.

## Consequences

- `statifier_persistence` **0.12.0** is a breaking minor: renamed modules,
  renamed types, renamed behaviour callbacks, a renamed facade, a renamed table,
  renamed telemetry, and a new donedata key. The release order for the family is
  `sp 0.12.0` then `ots 0.6.0` then `sob 0.10.0`, `sui 0.10.2` and the
  `statifier-ex` doc corrections, then `sb 0.28.0`, then the
  `statifier_examples` re-pin.
- Two transitional readers exist and both expire in `0.13.0`: the `:runs`
  `Config` alias (decision 3) and the old donedata key (decision 4). Each logs a
  deprecation line while it lives, so a host learns it is relying on one without
  reading a changelog.
- An out-of-tree storage adapter does not compile against `0.12.0` until it
  renames seven callbacks. That is the cost decision 6 chose on purpose, and it
  is the single loudest consequence of this record.
- A running install upgrades by running V06. The migration is a catalog rename
  with a `down/0`, so the rollback path is real, but an install that rolls the
  *code* back without rolling the migration back finds a table it cannot name.
  The changelog says to roll both or neither.
- Anything subscribed to `[:statifier_persistence, :run, ...]` goes silent at
  `0.12.0` with no error. Decision 5 accepted that in exchange for not paying the
  break twice; a host that wires its own handlers must grep for the old prefix as
  part of the upgrade, and the changelog says so.
- The records that use `run` as a defined term - ADR-0004, ADR-0006, ADR-0008,
  ADR-0009, ADR-0010 - are not rewritten. Each gets one dated Note pointing here
  (sp-478 for ADR-0004/0006/0009/0010, sp-pcw for ADR-0008), so a reader of an
  older record learns the noun moved without this campaign editing accepted text.
  ADR-0002's title keeps the phrase "runs vocabulary"; its Note carries the
  correction.
- This record merges at **proposed** and flips to accepted by **sp-5nv**, after
  sp-op4 (the code) and sp-j2y (the migration and the `Config` key) are on
  `main`. A flip verifies every claim above against the code of that day, not
  against this text.
- What would reopen this record: a host finding that the V06 in-place rename
  cannot run on its install (a name collision with a pre-existing
  `statifier_executions`, which would need a decision about the collision rather
  than an amendment to the rename); a decision to give the `inputs` table the
  same treatment, which this record declined; or the family choosing a different
  noun for the *session*-scoped things this package does not own, which would be
  `statifier-ex`'s call and not an amendment here.
