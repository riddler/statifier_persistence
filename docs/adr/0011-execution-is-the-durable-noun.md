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
  moduledoc from `telemetry.ex:58` (@70d86bd). The attributes are private, but
  the six documented emitters that publish them are not: `run_step_start/3`
  (`telemetry.ex:218`, `def run_step_start(run_id, entry, span_ref)`, @70d86bd),
  `run_step_stop/2` (`telemetry.ex:235`), `run_lock/2` (`telemetry.ex:261`),
  `run_created/1` (`telemetry.ex:321`), `run_terminated/1` (`telemetry.ex:342`)
  and `run_discarded/1` (`telemetry.ex:359`), all @70d86bd.
- **The second behaviour a host implements.** ADR-0004 decision 5's pluggable
  per-run serialization strategy is a second `@behaviour`, not a variation on
  the storage adapter: `StatifierPersistence.Serialization`'s one callback
  `with_run/3` (`lib/statifier_persistence/serialization.ex:29`, `@callback
  with_run(config :: term(), run_id :: String.t(), fun :: (-> result))`,
  @70d86bd), and the strategy this package ships,
  `StatifierPersistence.Serialization.AdapterLock.with_run/3`
  (`lib/statifier_persistence/serialization/adapter_lock.ex:22`, `def
  with_run(%Storage{} = store, run_id, fun)`, with `@behaviour
  StatifierPersistence.Serialization` at `adapter_lock.ex:14`, @70d86bd).
- **The linkage helper.** `Run.Linkage.child_run_id/3`
  (`lib/statifier_persistence/run/linkage.ex:285`, `def
  child_run_id(parent_run_id, invoke_id, child_index)`, `@spec` at `:280`,
  @70d86bd), the pure derivation of a child's id.
- **The public types outside the adapter.** `Runs.run_id/0` (`runs.ex:111`,
  `@type run_id :: Adapter.run_id()`, @70d86bd), `Storage.run_write_opt/0`
  (`storage.ex:114`, @70d86bd), the `run_id:` key of `Executor.context/0`
  (`lib/statifier_persistence/executor.ex:17`, `@type context :: %{run_id:
  String.t(), content_hash: String.t()}`, @70d86bd) and
  `Ecto.KeyGenerator.table/0` (`lib/statifier_persistence/ecto/key_generator.ex:28`,
  `@type table :: :charts | :positions | :runs | :inputs`, @70d86bd).
- **The records.** ADR-0004, ADR-0006, ADR-0008, ADR-0009 and ADR-0010 all use
  `run` as a defined term. ADR-0002 goes further and *decides* the word:
  decision 5, "**The vocabulary is *runs*, not sessions**"
  (`docs/adr/0002-configurable-keys-and-table-names.md:110`, @70d86bd), is the
  standing ruling this record overturns. ADR-0002's own title says nothing about
  a vocabulary - it is "Storage keys and table names are host-configurable;
  engine identities are not" (`0002-configurable-keys-and-table-names.md:1`,
  @70d86bd) - and the phrase "runs vocabulary" appears in the index summary at
  `docs/adr/README.md:6` (@70d86bd) rather than in that record. What makes the
  physical table name configurable at all is ADR-0002 decisions **3 and 4**
  (`0002-configurable-keys-and-table-names.md:66` and `:88`, @70d86bd), not
  decision 5.

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

- **Table names are already host-configurable.** ADR-0002 decisions 3 and 4
  (`0002-configurable-keys-and-table-names.md:66` and `:88`, @70d86bd) make the
  physical names a host's choice through `:tables` and `:table_prefix`, so the
  rename decided here changes the *default* names and the *key* that selects
  them, not a name a host cannot move.
- **The word itself was decided, and is being re-decided.** ADR-0002 decision 5
  (`0002-configurable-keys-and-table-names.md:110`, @70d86bd) fixed "runs" as
  this package's vocabulary against "sessions". Decision 1 below supersedes that
  ruling on the noun; the rest of ADR-0002 decision 5 - that "session" keeps the
  meaning `statifier-ex` gives it, and that the durable row carries the engine
  `session_id` as a nullable column - is untouched.
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

Decision 1 is a **rule**, and the rule - not this section's tables - is what
binds. It governs **every public surface of this package**, whether or not a
table below names it. A surface is in scope if it spells `run`, `runs` or
`run_id` in any of:

- a module or a function **name**;
- a **type**, either by its own name or in a **key of its own shape** - a map
  key inside a `@type`, at any depth, including a type whose name is innocent;
- a **callback** on either public behaviour;
- a **telemetry** event name or a metadata key;
- a public **telemetry metadata value** that belongs to a documented closed
  vocabulary - a value a host pattern-matches on, enumerated in
  `StatifierPersistence.Telemetry`'s moduledoc or in `docs/telemetry.md` -
  even where the key carrying it is innocent;
- a public **error atom**, including a member of an error union;
- a **generated** module name or schema field that a host's `use` produces;
- a surrogate-key **prefix**, or the map key that selects one.

The tables below are **illustrative of that rule, not exhaustive**. They exist
to show what the rename looks like in each category, to fix the arities, and to
record the handful of deliberate non-renames; they are not a checklist a later
reader may treat as complete, and a surface absent from them is renamed all the
same. Where a table and the rule appear to disagree, the rule wins.

The **authoritative enumeration** is the changelog fragment **sp-op4** writes.
It is produced by grep over `lib/` at the SHA the rename lands on, and it is
pinned by a test in sp-op4 asserting that no public `@type`, `@spec`,
`@callback`, `def`, `@doc`'d module name, error atom or telemetry name in
`lib/` spells `run`, `runs` or `run_id`.

That test carries one more clause, for the metadata-value bullet above: **no
documented telemetry metadata value spells the retired noun**. The checkable
form is a grep over `lib/` for *atom literals* - `:run`, `:runs`, and any atom
ending `_run` or `_runs` - failing on every hit outside the named survivors.
That shape is chosen over "walk `Telemetry`'s documented vocabulary" because
the vocabularies are prose in a moduledoc table and in `docs/telemetry.md`, not
a value a test can read: `Telemetry.fields/0` is `keyword()` and no public
`@type` enumerates them, so only the atom literals at the call sites are
mechanically checkable. On this clause the survivor list is **empty**: after
decision 3 there is no `:runs` `Config` alias to spare, and the historical
migrations that used to hold nine further `:runs` atom literals are rewritten
by that same decision, so no `migrations/` exemption is needed either. Every
`:run`, `:runs`, `_run` or `_runs` atom literal left in `lib/` is a miss.

That test names its permitted survivors, and there are exactly two - neither
of them an atom literal, which is why the clause above admits none:

1. the old donedata key `statifier_persistence:run_status`, which decision 4
   keeps **readable** for one release. It is a **string** literal, not an
   atom, so it survives the atom-literal clause by construction and is named
   here so the broader `run`-spelling arm of the test spares it;
2. `run` as the ordinary English verb in prose and in a private name, which
   decision 1 keeps.

Anything else the test finds is a surface this rule already renamed and sp-op4
has missed.

Within the tables, the left column is today's name at `70d86bd` with today's
arity, read off the definition rather than off any bead text; the right column
is the name after sp-op4. Arity is part of a name, so a row whose arity differs
on the two sides would be a change of shape and not a rename - there is no such
row.

Where a definition ends in a default argument it exports two arities, and the
left column gives the **maximum**. That is the case for `Storage.insert_run/5`
and `Storage.update_run/5` (`opts \\ []`, `storage.ex:309` and `:359`,
@70d86bd), `Storage.update_run_status/4` (`storage.ex:401`, @70d86bd), and, in
the Context list above, `Runs.fail/4` (`runs.ex:490`), `Runs.cancel/3`
(`runs.ex:558`) and `Runs.cascade_cancel/3` (`runs.ex:634`), all @70d86bd. Both
arities of each are renamed together; the rename is unaffected either way.
Arities are read per layer, because the two layers genuinely differ: the
`Storage.Adapter` callback is `update_run/2` (`adapter.ex:344`) while the
`Storage` function of the same name is `update_run/5` (`storage.ex:354`), and
the adapter's `list_runs_by_metadata/2` (`adapter.ex:422`) and the facade's
`list_runs_by_metadata/2` (`storage.ex:551`) agree only by coincidence.

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

One more `Storage.Adapter` type is in scope by its *shape* rather than its
name, and it is the one an out-of-tree adapter builds and reads for ADR-0010's
two optional callbacks:

| Today (@70d86bd) | After |
|---|---|
| `input_record/0`'s `run_id:` key (`adapter.ex:151-156`, `@typedoc` at `:140`) | `execution_id:` |

The type keeps its own name - an input record is still an input record - and
only its key moves.

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
segment; their `run_id`-shaped metadata keys move, per the rows above, and
on `[:statifier_persistence, :identity, :refused]` one metadata *value* moves
too (the `stage:` row below).

**Telemetry metadata values**

Two metadata *values* spell the noun under keys that do not. Both are members
of a documented closed vocabulary a host pattern-matches on, so both are in
scope by the metadata-value bullet of this decision's rule, and both rename:

| Today (@70d86bd) | After |
|---|---|
| `stage: :run` on `[:statifier_persistence, :identity, :refused]` (`storage.ex:313` and `:363`, `refuse_unidentified(:run, run_id: run_id)`; `storage.ex:714`, `precheck_identity(..., :run, keys)`; emitted at `storage.ex:830` and `:838` into `Telemetry.identity_refused/1`, `telemetry.ex:304`; documented at `docs/telemetry.md:238` and `:258`, "`stage` is `:position`, `:run` or `:chart`") | `stage: :execution` |
| `reason: :terminal_run` on `[:statifier_persistence, :run, :discarded]` (`runs.ex:428`, `:527`, `:567`, each `discarded(run_record, run_id, _, :terminal_run)` into `runs.ex:867`; documented at `telemetry.ex:102` and `docs/telemetry.md:291`) | `reason: :terminal_execution` |

The private specs that type the first of these travel with it and are renamed
in the same pass, without being public surface in their own right: `@spec
refuse_unidentified(:chart | :position | :run, keyword())` (`storage.ex:827`,
@70d86bd), `@spec refuse_mismatch(:position | :run, keyword(), Identity.t(),
Identity.t())` (`storage.ex:835`, @70d86bd), and the `stage :: :position |
:run` parameter of `@spec precheck_identity/4` (`storage.ex:797`, @70d86bd).
The `docs/telemetry.md` prose that enumerates both vocabularies is updated in
the same pass.

By contrast the `callback` metadata values on
`[:statifier_persistence, :adapter, :call]` (`docs/telemetry.md:240-243`,
@70d86bd) need no row: they *are* the `Storage.Adapter` callback names, so they
rename transitively with the callback table above.

**`StatifierPersistence.Telemetry` emitters**

The six documented functions that publish the renamed events rename with them.
The other ten emitters (`adapter_call/2`, `identity_refused/1`,
`effect_failed/1`, `drive_turns_exhausted/2` and the six `child_*` emitters,
`telemetry.ex:279` through `:520`, @70d86bd) keep their names; their
`run_id`-shaped metadata keys move, and `identity_refused/1`'s `stage:` value
moves as well (the metadata-value table below).

| Today (@70d86bd) | After |
|---|---|
| `run_step_start/3` (`telemetry.ex:218`) | `execution_step_start/3` |
| `run_step_stop/2` (`telemetry.ex:235`) | `execution_step_stop/2` |
| `run_lock/2` (`telemetry.ex:261`) | `execution_lock/2` |
| `run_created/1` (`telemetry.ex:321`) | `execution_created/1` |
| `run_terminated/1` (`telemetry.ex:342`) | `execution_terminated/1` |
| `run_discarded/1` (`telemetry.ex:359`) | `execution_discarded/1` |

**The `StatifierPersistence.Serialization` behaviour**

This is the *second* behaviour a host may implement (ADR-0004 decision 5), and
it renames too. A host that supplied its own strategy module implements one
renamed callback; the shipped `AdapterLock` strategy is renamed with it.

| Today (@70d86bd) | After |
|---|---|
| `@callback with_run/3` (`serialization.ex:29`) | `@callback with_execution/3` |
| `AdapterLock.with_run/3` (`serialization/adapter_lock.ex:22`) | `AdapterLock.with_execution/3` |

The callback's `run_id :: String.t()` parameter becomes `execution_id ::
String.t()`. `StatifierPersistence.Serialization` and
`StatifierPersistence.Serialization.AdapterLock` keep their module names: they
name a strategy, not the durable record.

**`StatifierPersistence.Run.Linkage`**

| Today (@70d86bd) | After |
|---|---|
| `child_run_id/3` (`run/linkage.ex:285`) | `child_execution_id/3` |

`new/4`, `new/6`, `fan_out?/1`, `to_metadata/1`, `from_metadata/1`,
`parent_match/1`, `invocation_match/2` and `reserved_key/0` keep their names;
their `parent_run_id` parameters are parameter names, covered by the closing
paragraph of this decision.

**Public types outside `Storage.Adapter`**

| Today (@70d86bd) | After |
|---|---|
| `Runs.run_id/0` (`runs.ex:111`) | `Executions.execution_id/0` |
| `Storage.run_write_opt/0` (`storage.ex:114`) | `Storage.execution_write_opt/0` |
| `Storage.input/0`'s `run_id:` key (`storage.ex:89-94`, `@typedoc` at `:79`) | `execution_id:` |
| `Executor.context/0`'s `run_id:` key (`executor.ex:17`) | `execution_id:` |
| `Ecto.KeyGenerator.table/0` = `:charts \| :positions \| :runs \| :inputs` (`ecto/key_generator.ex:28`) | `:charts \| :positions \| :executions \| :inputs` |

`KeyGenerator.table/0` is load-bearing rather than cosmetic: it is the type a
host's own key generator is written against, and decision 3 moves `@table_keys`
to `:executions`, so leaving this type enumerating `:runs` would type a host
against a key that no longer exists. `Executor.context/0` is the map an
`Executor.execute/2` implementation receives, so its key rename is a break for
every host effect executor, not an internal detail.

**`StatifierPersistence.Driver`**

`Driver` has no `run`-named function, so a name-only sweep misses it; it is in
scope by the shape of its public type. `dispatch_context/0` is the map handed to
a **host-supplied** `:dispatch` function, so its key rename is the same silent,
non-compile-time break class as `Executor.context/0`.

| Today (@70d86bd) | After |
|---|---|
| `Driver.dispatch_context/0`'s `run_id:` key (`driver.ex:205-210`) | `execution_id:` |

`Driver`'s nine public functions - `new/3` (`driver.ex:412`), `create/3`
(`:437`), `send_event/4` (`:484`), `done_invocation/5` (`:520`),
`failed_invocation/5` (`:545`), `parent_link/2` (`:561`), `answer_parent/3`
(`:603`), `resolve_and_answer_parent/3` (`:652`) and `start_child_at/6`
(`:735`), all @70d86bd, arities given as the maximum where the definition ends
in a default argument - keep their names. Eight of the nine (every one but
`new/3`) take a `run_id`-shaped parameter typed `Runs.run_id()`; the **type**
renames by the row above in "Public types outside `Storage.Adapter`", and the
parameter names follow the closing paragraph of this decision.

**Public error atoms**

Error atoms are returned values a host pattern-matches on, so they break exactly
like a function name, and being union *members* rather than named types does not
put them outside decision 1.

| Today (@70d86bd) | After |
|---|---|
| `Storage.error/0`'s `:run_position_missing` (`storage.ex:67-77`, member at `:71`) | `:execution_position_missing` |
| `Storage.error/0`'s `:run_outcome_unsupported` (`storage.ex:74`) | `:execution_outcome_unsupported` |
| `Storage.error/0`'s `:run_states_unsupported` (`storage.ex:75`) | `:execution_states_unsupported` |
| `Storage.Adapter.error/0`'s `:run_exists` (`adapter.ex:199-208`, member at `:202`) | `:execution_exists` |
| `Storage.Adapter.error/0`'s `:run_not_found` (`adapter.ex:203`) | `:execution_not_found` |
| `Storage.Adapter.error/0`'s `:run_outcome_unsupported` (`adapter.ex:205`) | `:execution_outcome_unsupported` |
| `Storage.Adapter.error/0`'s `:run_states_unsupported` (`adapter.ex:206`) | `:execution_states_unsupported` |

`Storage.error/0` unions `Adapter.error/0` (`storage.ex:68`, @70d86bd), so the
last four rows reach the facade through it and are not repeated there. The
`:refused` forms an adapter answers at open with the same atoms
(`adapter.ex:432` and `:464`, @70d86bd) carry the renamed atoms too.

**The generated host schema modules**

`use StatifierPersistence.Ecto` generates four Ecto schema modules under the
host's namespace (`ecto.ex:64`'s `@schema_modules` entry `{Run, :runs}`,
concatenated at `ecto.ex:128`, documented at `ecto.ex:15-17`, all @70d86bd).
They are not literal `defmodule`s in this package, but their names are public:
a host writes `MyApp.Persistence.Run` in its own queries.

| Today (@70d86bd) | After |
|---|---|
| `MyApp.Persistence.Run` (`ecto.ex:64`, `:128`, documented `:15-17`) | `MyApp.Persistence.Execution` |
| the executions schema's `run_id` field (`ecto.ex:91`) | `execution_id` |
| the inputs schema's `run_id` field (`ecto.ex:102`) | `execution_id` |
| the table the module binds (`ecto.ex:64`'s `:runs` key) | `:executions`, resolving to `statifier_executions` by decision 3 |

**The surrogate-key prefix**

`Ecto.KeyGenerator.UXID`'s `@prefixes` map (`ecto/key_generator/uxid.ex:18`,
@70d86bd) is `%{charts: "chart", positions: "pos", runs: "run", inputs:
"input"}`. Its keys are the same atoms decision 3 renames, so the `:runs` key
**must** become `:executions` or `Map.fetch!/2` at `uxid.ex:30` (@70d86bd)
raises for the renamed table.

| Today (@70d86bd) | After |
|---|---|
| `@prefixes`' `runs:` key (`uxid.ex:18`) | `executions:` |
| its prefix string `"run"` (`uxid.ex:18`) | `"exec"` |

The **prefix string changes too**, and that is a deliberate choice rather than a
mechanical consequence: the key could have been respelled while the prefix stayed
`"run"`. `"exec"` is chosen because the prefix's stated purpose is that "a key
met in a psql console or a log line names its table" - a sentence written in
the generator's own moduledoc (`uxid.ex:5-8`, @70d86bd), which derives it from
"ADR-0002 decision 4, as amended". ADR-0002 decision 4 itself
(`docs/adr/0002-configurable-keys-and-table-names.md:88-95`, @70d86bd) settles
**table** names on that discoverability argument ("someone meeting
`statifier_runs` in a psql console knows where it came from"); the extension of
the same argument to key prefixes is the moduledoc's, and it is the moduledoc
this record relies on. Either way, a `run_` prefix on a row in
`statifier_executions` would defeat exactly that, and it would leave the
retired noun as the most
frequently *read* word this package produces. `"exec"` is preferred over
`"execution"` for the same reason the map already says `"pos"` and not
`"position"`: these prefixes are short.

The consequence is stated plainly here rather than left to be discovered:

- New rows carry `exec_...`. On an upgraded install **existing rows keep
  `run_...`** - decision 3's V06 renames the table and the columns and copies
  **no data**, so every id already stored is unchanged and stays valid. A fresh
  install only ever holds `exec_...`.
- An id is an opaque string. Nothing in this package parses a prefix, and no
  host should; a host that does must accept **both** spellings indefinitely,
  because both will coexist in the same column forever.
- This is a deliberate breaking change, taken under the pre-1.0 latitude this
  record relies on throughout. A host that cannot accept it can supply its own
  key generator - `Ecto.KeyGenerator` is a public behaviour precisely so that
  the prefix scheme is replaceable.

Private functions, local variables, parameter names, test names and doc prose
follow the same rename without being enumerated here: the tables fix the
*public* surface, and the rest is consistency work sp-op4 does in the same pass.
Three things are deliberately absent from the tables rather than overlooked.
`Executor.run/3` (`executor.ex:50`) is not public - it carries `@doc false` at
`executor.ex:47` and its own comment calls it package-internal - and in any case
it is the English verb, which decision 1 keeps. The in-tree adapters'
implementations of the renamed callbacks (`Storage.Ecto` and `Storage.InMemory`,
e.g. `Storage.InMemory.insert_run/2` at `storage/in_memory.ex:116`, @70d86bd)
rename mechanically with the callbacks they implement and are not listed
separately. And `StatifierPersistence.Run.from_record/1` (`run.ex:36`, @70d86bd)
keeps its function name, travelling to `Execution.from_record/1` with its
module's row above.

### 3. The tables, the columns, the indexes, the rewritten V01-V05, the conditional V06, and the `Config` key

- The `:runs` table key becomes `:executions`, so `@table_keys`
  (`ecto/config.ex:46`, @70d86bd) becomes
  `[:charts, :positions, :executions, :inputs]` and the shipped default name
  becomes **`statifier_executions`**.
- **There is no `:runs` alias.** `:executions` is the only spelling the
  configuration accepts. Supplying `:runs` under `tables:` reaches
  `Config.table/2`'s `when table in @table_keys` guard (`ecto/config.ex:90`,
  @70d86bd) and raises like any other unknown key. A one-release alias with a
  deprecation log line was considered and rejected: it would have to survive
  in the historical migrations as well as in host configuration, and this
  package is pre-1.0 - the cutover is taken once, loudly, in `0.12.0`, rather
  than half-taken and finished in `0.13.0`.
- The `:inputs` key and the table name `statifier_inputs` are **unchanged**.
- The `run_id` column becomes `execution_id` in **both** tables: the executions
  table (V01's `add(:run_id, :text, null: false)`, `v01.ex:68`, @70d86bd) and
  the input log (V05's `add(:run_id, :text, null: false)`, `v05.ex:51`,
  @70d86bd).
- **The historical migrations V01-V05 are rewritten to the new noun.** Every
  `Config.table(config, :runs)` call site becomes
  `Config.table(config, :executions)` - nine `:runs` atom literals in all:
  `v01.ex:64` (`runs = Config.table(config, :runs)`) and `v01.ex:88` (`for
  name <- [:runs, :positions, :charts]` in `down/1`), `v02.ex:32` and `:42`
  (`alter table(Config.table(config, :runs), ...)`), `v03.ex:86` and `:108`,
  and `v04.ex:156`, `:160` and `:165` (the qualified-name helpers and the
  concurrent rebuild), all @70d86bd. Every `run_id` column and index those
  versions declare is declared as `execution_id`: V01's column (`v01.ex:68`)
  and its unique index on `(run_id)` (`v01.ex:80`), and V05's column
  (`v05.ex:51`) and its unique index on `(run_id, seq)` (`v05.ex:60`), all
  @70d86bd. The GIN index name V03 and V04 derive from the table name
  (`v03.ex:126` and `v04.ex:191`, @70d86bd) follows the table.
- **A fresh install therefore creates the execution tables directly.**
  Running V01 through V06 against an empty database never creates
  `statifier_runs` at any point: V01 creates `statifier_executions` with an
  `execution_id` column, and V06 finds nothing to rename.
- **Migration V06 is a conditional in-place rename.** When the resolved *old*
  name (the configured table prefix plus `runs`, or the `tables:` override a
  host gave for that table) exists, `up/1` renames **in place**: the table,
  the two `execution_id`-to-be columns, V01's unique index on `(run_id)`,
  V05's unique index on `(run_id, seq)` and V03/V04's `metadata` GIN index. It
  copies no data - a rename is a catalog operation and this record forbids any
  variant that reads or writes rows. When the old name does **not** exist -
  the fresh install above - `up/1` is a **no-op**.
- **V06 is a version this package knows either way.** It takes the key `6` in
  `Migrations`' `@migrations` map (`ecto/migrations.ex:110-116`, @70d86bd),
  from which `@current_version` (`ecto/migrations.ex:121`, `@migrations |>
  Map.keys() |> Enum.max()`) and `expected_version/0`
  (`ecto/migrations.ex:203`) are derived, so
  `Migrations.up/1` runs it and `expected_version/0` answers `6`. This package
  writes no versions table, no marker row and no version column
  (`ecto/migrations.ex:190-195`, @70d86bd: "there is no
  `assert_version!/1` ... this package records none"), so there is no other sense in
  which a version is "recorded": the map entry and the host's own
  `schema_migrations` timestamp are the whole of it.
- **How V06 tells the two installs apart.** It asks the repo whether the
  resolved old name exists, and it asks *late*: the probe goes through
  `Ecto.Migration.execute/1`'s function form, which the migration runner
  executes in order after the DDL queued ahead of it, rather than running in
  the body of `up/1`. That is the shape V04 already uses for exactly this
  reason (`v04.ex:121-132`, @70d86bd: "The check goes through `execute/1`'s
  function form rather than running here ... asking the runs table anything
  from the body of `up/1` reaches it before V01 has created it, on every fresh
  database"). The catalog query itself is sp-j2y's to write per adapter; this
  record fixes the question, not the SQL.
- **`down/0` renames back when the executions table exists**, and does nothing
  when it does not. It does **not** try to tell a fresh install from an
  upgraded one: nothing in the schema records which path built the database,
  and a marker that did would be new stored surface bought for one migration.
  So the rollback is unconditional-on-existence, and the consequence is the
  next bullet.
- **Rolling back below V06 on an upgraded install is unsupported.** V06's
  `down/0` restores `statifier_runs` with `run_id` columns, but V01-V05's
  `down/1` arms now speak `:executions` and `execution_id`, so they no longer
  name the tables V06's `down/0` just renamed back. A **fresh** install rolls
  back normally: nothing renames on the way down, and V01-V05 drop exactly
  what they created. This record accepts that asymmetry rather than carrying a
  compatibility shim through the historical migrations: the package is pre-1.0
  (`mix.exs:4`, `@version "0.11.0"`, @70d86bd), an upgraded install that must
  go back reaches for its backup or for `0.11.x` with its own `0.11.x`
  migrations, and the changelog says so in those words.
- A host that already set `:tables` or `:table_prefix` explicitly keeps
  whatever it set; V06 renames from the resolved old name to the resolved new
  name, which is what makes it correct under ADR-0002 decisions 3 and 4.
- The generated host schema module and the surrogate-key prefix move with the
  table key, and decision 2's last two tables give their rows:
  `MyApp.Persistence.Run` becomes `MyApp.Persistence.Execution` over
  `statifier_executions`, and the UXID prefix for that table becomes `"exec"`.
  Because V06 copies no data, an **upgraded** install's existing ids keep
  their `run_` prefix while new ids get `exec_`; both are valid, opaque, and
  coexist permanently. A fresh install only ever writes `exec_`.
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
  reads only `statifier_persistence:execution_status`. It is the **only**
  transitional reader this rename ships: decision 3 takes the configuration and
  the tables over in one step, with no alias to retire later.
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

### 6. No callback shim: **both** behaviours break, and the changelog says what to do

Decision 2 renames callbacks on **two** behaviours a host implements, and both
are a hard break:

- `StatifierPersistence.Storage.Adapter` - seven renamed callbacks - for any
  out-of-tree storage adapter.
- `StatifierPersistence.Serialization` - one renamed callback, `with_run/3` to
  `with_execution/3` - for any host that supplied its own per-execution
  serialization strategy under ADR-0004 decision 5. A host that left the
  strategy at its default (`AdapterLock`) implements nothing and is unaffected
  by this one.

This record deliberately ships no compatibility layer for either: no
`defoverridable` bridge, no `__using__` macro that defines the old names, no
`Code.ensure_loaded?`-style dispatch that tries the new callback and falls back
to the old one. This package is pre-1.0; a break that a host fixes once, guided
by the compiler, is cheaper than a synonym the family carries forever.

- A behaviour with two accepted spellings is a behaviour with no contract: the
  `@callback` list is what `@behaviour` checks, and a shim makes the compiler
  stop telling an adapter author that they have not migrated.
- The break is mechanical and total. An adapter implements seven renamed
  callbacks and a custom strategy implements one, both changing no logic; the
  compiler names every one of them.
- The `0.12.0` changelog fragment therefore carries **Breaking for storage
  adapters** in bold and says what to do about it - the rename tables of
  decision 2, the fact that no behaviour beyond the names changed, and, named
  separately because it is easy to miss, the `Serialization` callback rename for
  a host running a custom strategy (`changelog.d/README.md:64`, "say what to do
  about it"). sp-op4 and sp-j2y write that fragment; this record does not.

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
  renamed types, renamed callbacks on both public behaviours, a renamed facade,
  a renamed table, renamed telemetry emitters and event names, and a new
  donedata key. The release order for the family is: **`sob 0.10.0` shipped
  ahead**, on 2026-09-12 (`statifier_oban` CHANGELOG `[0.10.0] 2026-09-12`,
  @`e3422bb`) - its half is a parameter name and documentation only, it changes
  no job argument, unique key or telemetry name, and `statifier_oban` takes no
  `statifier_persistence` dependency at all (`statifier_oban/mix.exs` deps,
  @`e3422bb`), so nothing made it wait; then `sp 0.12.0`; then `ots 0.6.0` in
  lockstep with it (decision 5); then `sui 0.10.2` and the `statifier-ex` doc
  corrections; then `sb 0.28.0`, which carries the donedata key of decision 4;
  then the `statifier_examples` re-pin. The version named for `statifier_oban`
  in this wave is therefore spent: any further `statifier_oban` change this
  rename forces would be `0.10.1`.
- Exactly **one** transitional reader exists, and it expires in `0.13.0`: the
  old donedata key (decision 4), which logs a deprecation line while it lives
  so a host learns it is relying on it without reading a changelog. The
  configuration takes no alias at all (decision 3), so there is nothing else
  to retire in `0.13.0`.
- An out-of-tree storage adapter does not compile against `0.12.0` until it
  renames seven callbacks, and a host-supplied serialization strategy does not
  compile until it renames one. That is the cost decision 6 chose on purpose,
  and it is the single loudest consequence of this record. Both breaks are
  deliberate and unshimmed: this package is pre-1.0, and the release notes say
  so plainly rather than softening it.
- A host effect executor breaks too, quietly rather than at compile time: the
  `context` map it receives arrives with `execution_id:` instead of `run_id:`
  (decision 2's type table). An implementation that pattern-matches `%{run_id:
  id}` raises at the first effect; one that reads the key by name gets `nil`.
  A host-supplied `:dispatch` function breaks the same way, on
  `Driver.dispatch_context/0`'s key. The changelog names both beside the two
  behaviours.
- A host that pattern-matches this package's **error atoms** breaks quietly in
  the same class: `{:error, :run_not_found}` becomes
  `{:error, :execution_not_found}`, and a `case` with no catch-all raises while
  one with a catch-all silently reclassifies a known refusal as an unknown
  failure. Decision 2's error-atom table is the list; the changelog reproduces
  it.
- **New surrogate ids change prefix** (`run_` to `exec_`) while every stored id
  keeps the one it has, because V06 copies no data. Nothing in this package
  parses a prefix and no host should, but a host that does must accept both
  spellings permanently. The changelog says so in the same breath as the
  migration.
- **A fresh install** creates the execution tables directly: V01-V05 are
  rewritten to the new noun, so `statifier_runs` is never created and V06 is a
  no-op that only advances the version this package expects. **An upgraded
  install** runs V06, which finds the old table and renames it, its two
  columns and its three indexes in place, copying no data.
- **Rolling back below V06 on an upgraded install is unsupported**, because the
  rewritten V01-V05 `down/1` arms speak the new noun while V06's `down/0` has
  just restored the old one; a fresh install rolls back normally. The changelog
  carries this in bold - **Breaking for hosts that rolled back below V06 or
  that reference the runs table by name** - and says what to do instead: keep a
  backup, or go back to `0.11.x` and use its migrations.
- A host that names the table itself - in a raw query, a view, a materialized
  view, a hand-written Ecto schema or a monitoring dashboard - breaks at
  `0.12.0` whichever path it took, because the name is `statifier_executions`
  on both. The changelog names this beside the rollback line.
- Anything subscribed to `[:statifier_persistence, :run, ...]` goes silent at
  `0.12.0` with no error. Decision 5 accepted that in exchange for not paying the
  break twice; a host that wires its own handlers must grep for the old prefix as
  part of the upgrade, and the changelog says so.
- The records that use `run` as a defined term - ADR-0004, ADR-0006, ADR-0008,
  ADR-0009, ADR-0010 - are not rewritten. Each gets one dated Note pointing here
  (sp-478 for ADR-0004/0006/0009/0010, sp-pcw for ADR-0008), so a reader of an
  older record learns the noun moved without this campaign editing accepted text.
- **ADR-0002 decision 5 is the one live decision this record overturns**, and its
  dated Note must say so rather than merely pointing here: after sp-5nv flips
  this record, ADR-0002 decision 5's "the vocabulary is *runs*" no longer holds,
  while the rest of that decision (what "session" means, and the nullable
  `session_id` column) does. ADR-0002's own title is unaffected - it names
  configurability, not a vocabulary - and the phrase "runs vocabulary" that needs
  a corresponding correction lives in the index summary at
  `docs/adr/README.md:6` (@70d86bd).
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
