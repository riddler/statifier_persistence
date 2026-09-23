# ADR-0013: The migration plan: one plan per pair of chart hashes, a transform over the engine's export applied by its import, two validations, whole or nothing, a telemetry event and no stored trace, timers read through host pin sources and refused without one, children untouched, three owners

Status: proposed (2026-09-23, sp-bn0)

## Context

An execution is pinned to one chart. Its stored row carries the content hash
of the chart it walks, and every load of its position goes through the
identity guard (ADR-0003 decision 2), which refuses a machine whose identity
is not the one the position was saved against. That is the property that
keeps a deploy from silently resuming the wrong configuration, and it has a
cost: an execution that waits for days outlives the revision of the document
it started on, and today there is exactly one thing a host can do about that -
let it finish on the old chart. ADR-0012 made the "let it finish" half
operable (the drained query, then retirement). This record decides the other
half: moving one waiting execution onto a newer chart, on purpose, as an
explicit act, and refusing the whole move when any part of it cannot be
honoured.

Four nouns carry the design, one job each. A **document** is the host's
stable name for a thing it authors. A **revision** is one saved edit of that
document. A **chart** is the SCXML a revision emits, identified by its content
hash. An **execution** is pinned to one chart hash, and is re-pinned only by
the explicit migration this record decides. A workflow has executions.

### The case this record is written against

A library hold. A patron places a hold on a title; when a copy is routed to
the patron's branch the hold's execution enters `awaiting_pickup`, whose
`onentry` schedules the pickup deadline as a delayed send
(`<send id="pickup" event="pickup.expired" delay="..."/>`), and it waits
there for `copy.collected` or `pickup.expired`. While executions wait in
`awaiting_pickup`, the library edits the document: `awaiting_pickup` is
renamed `ready_for_pickup`, and the step before it - the one that routes the
copy to the pickup branch - gains a `transferred` outcome leading to a new
state. The waiting execution must land in `ready_for_pickup` with its pickup
deadline unchanged, or the migration is refused with its chart, identity and
position unchanged (under `on_failure: :park` the refusal also writes its
status, the one exception decision 4 names).

In a chart a host writes by hand, that edit is a rename of a state id. In a
chart statifier_blocks compiles, the wait block keeps its block id when its
label changes, so its state id does not change at all and the same edit maps
the state to itself; the new outcome adds a state on the new side that
nothing maps from. The plan below has to express both.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`9cd192b`**
("Promotes the sp-l4p send-types fragment into the 0.13.0 section") and on
the engine at the version `mix.lock` resolves, **statifier 2.6.0**, read
2026-09-23. Every code cite carries the SHA or version it was read at and an
anchor beside it, because line numbers move and anchors do not.

- **The engine already has a migration vocabulary, and it is string ids.**
  `Statifier.Position.export/1` translates a position into a map keyed by
  author-written state ids - `configuration`, `entered_states` and
  `states_to_invoke` as sets of ids, `history_values` as a map of history id
  to a set of ids, `active_invocations` keyed by `{state_id, invoke_ordinal}`,
  and `invoke_counter`, `send_counter`, `timer_counter`, `datamodel` and the
  interpreter's bookkeeping fields carried verbatim
  (`deps/statifier/lib/statifier/position.ex`, `export/1` and
  `@required_export_keys`, statifier 2.6.0). It refuses a position whose
  internal queue is not empty with `{:error, :internal_queue_not_empty}`,
  and a position holding a state with no author-written id with
  `{:error, {:unnameable_states, indexes}}` (same file, `export/1`).
- **The engine's import is the apply, and it checks no identity.**
  `Statifier.Position.import/2` takes a machine and an export and rebuilds a
  position walking that machine; it performs no identity check at all, it
  collects every id the machine does not know and refuses with
  `{:error, {:unknown_state_ids, ids}}`, and it refuses a missing key or a
  wrong-shaped value with `{:error, {:malformed_export, reason}}`. It either
  answers a whole position or refuses (`import/2`, statifier 2.6.0).
- **The export is not JSON.** Its keys are atoms, its id sets are `MapSet`s
  and its invocation keys are tuples (`@type exported` and
  `translate_active_invocations/2`, statifier 2.6.0). A plan that a host
  stores, and that another package generates, needs an encoding of its own.
- **An execution is re-pinned by one adapter write, and the guard reads at
  load.** `Storage.update_execution/5` derives the identity, the content hash
  and the position blob from the machine state it is given and writes them in
  one full-record overwrite
  (`lib/statifier_persistence/storage.ex`, `update_execution/5`, @9cd192b);
  the Ecto adapter writes the three columns in one `update_all`
  (`lib/statifier_persistence/storage/ecto.ex`, `update_execution/2`,
  @9cd192b). The guard runs when a position is loaded, in
  `Storage.load_execution_position/3` (`storage.ex`,
  `load_execution_position/3`, @9cd192b).
- **Execution metadata is write-once.** `Storage.update_execution/5` accepts
  no `metadata:` option and the adapter carries the stored map forward
  (`storage.ex`, `update_execution/5` doc, @9cd192b; ADR-0006 decision 1).
- **A child's linkage pins the child's own chart, not the parent's.** The
  linkage's mandatory `content_hash` is the child machine's own identity hash
  (`lib/statifier_persistence/execution/linkage.ex`, `@enforce_keys`;
  `lib/statifier_persistence/driver.ex`, `create_child/6`, @9cd192b), and
  ADR-0008 decision 2 hardens that pin into contract. A parent names a live
  child through its `active_invocations` entry for that invocation.
- **The per-execution lock does not undo a returned error.** The Ecto
  adapter's `lock_execution/3` wraps the function in `repo.transaction/1`,
  so a function that returns `{:error, _}` commits whatever it wrote; only a
  raise or an explicit rollback undoes it
  (`storage/ecto.ex`, `lock_execution/3`, @9cd192b). The in-memory adapter's
  `lock_execution/3` is a mutex with no transaction at all
  (`lib/statifier_persistence/storage/in_memory.ex`, `lock_execution/3`,
  @9cd192b). Serialization reaches both through the strategy
  `Executions` selects (`lib/statifier_persistence/executions.ex`,
  `serialized/5`, @9cd192b).
- **Timers are not this package's, and a pin source answers counts.** A
  pending delayed send lives in the host's timer queue. The one seam this
  package has onto state held there is `StatifierPersistence.PinSource`,
  whose callback answers a map of atom to non-negative count for a content
  hash and a context of execution ids, and whose `collect/3` turns a source
  that cannot answer into a refusal (`lib/statifier_persistence/pin_source.ex`,
  `pins/2` and `collect/3`, @9cd192b). A count names no send id and no
  state. SCXML delayed sends are not scoped to a state either: a send
  scheduled on entry to one state stays pending after the execution leaves
  it.
- **There is no per-execution trace store.** The input log of ADR-0010 is
  a replay log of events the interpreter saw, keyed by a closed door
  vocabulary (ADR-0010 decision 5), and a migration delivers no event.
- **Nothing moves an execution to another chart today.** No entry point in
  `lib/` at `9cd192b` moves an execution to another chart.
  `Storage.update_execution/5` re-derives the content hash from the machine
  state it is handed, and its callers in `Executions` - the step write and
  the terminal repair - hand it a position loaded through the guard with the
  same machine, so nothing calls it with another chart's machine
  (`lib/statifier_persistence/executions.ex`, `write_execution/6` and
  `repair_terminal/4`, @9cd192b). The package's only migrations are the
  schema migrations under `StatifierPersistence.Ecto.Migrations`, which move
  tables, not executions.

## Decision

**1. A plan is data, one plan per pair of chart hashes, in one JSON-safe
encoding.** A plan names the chart it moves from and the chart it moves to,
by content hash, and says how every part of an export crosses between them.
It holds no expression, no function and no reference to IO, so a host can
store it, review it and hand it to another process. Its map form - the form
the codec writes and the only encoding of a plan - has string keys only;
the `states`, `history` and `invocations` fields statifier_blocks emits
(decision 8) are in this form:

```json
{
  "from": "<content hash of the chart the execution is on>",
  "to": "<content hash of the chart it moves to>",
  "states": {"awaiting_pickup": "ready_for_pickup"},
  "drop": [],
  "history": {},
  "invocations": [],
  "timers": {"keep_mapped": true},
  "datamodel": [
    {"op": "add", "key": "transfer_branch", "value": null}
  ]
}
```

That is the whole plan for the library hold as a hand-written chart. For the
same edit compiled by statifier_blocks, `states` is empty, because the wait
state's id is unchanged.

- `states` maps a source state id to a target state id. A state of the from
  chart the plan does not name maps to the state of the same id in the to
  chart, when the to chart has one; otherwise it is **unmapped**.
- `drop` lists source state ids the plan removes on purpose. A drop is the
  explicit alternative to a mapping: a dropped state is left out of every
  field of the export, and decision 5 says how it is reported.
- `history` maps a source history state id to a target history state id,
  with the same default as `states`. The values a history state recorded are
  translated through `states` and `drop`.
- `invocations` is a list of four-element lists,
  `[from_state_id, from_ordinal, to_state_id, to_ordinal]`, one per moved
  invocation; the ordinal is the engine's within-state document-order ordinal
  of an `<invoke>`, the integer half of an `active_invocations` key. **This is
  the one encoding of an invocation key in a plan**, in the map form and in
  JSON. An active invocation the list does not name maps to the same ordinal
  under its state's mapped id.
- `timers` has one key, `keep_mapped`, whose only admitted value is `true`
  (decision 6).
- `datamodel` is an ordered list of operations on top-level datamodel keys,
  each an object whose `op` is `"add"` (with `key` and `value`), `"rename"`
  (with `from` and `to`) or `"remove"` (with `key`). A value is a JSON literal - a string,
  number, boolean, null, list or object - and never an expression. An
  operation naming a key that begins with `_` is refused, because those are
  the engine's system variables.

The Elixir struct that holds a plan in memory is the implementing code's
choice; what crosses a package boundary or reaches storage is the map form
above.

**2. The plan is a transform over the engine's export, and the engine's
import on the to machine is the apply; nothing new is asked of the engine.**
A migration exports the execution's position with `Position.export/1`,
rewrites the export's state ids, history, invocation keys and datamodel as
the plan says, and hands the result to `Position.import/2` with the to
machine. Everything the plan does not touch crosses verbatim, including
`invoke_counter`, `send_counter` and `timer_counter`. The engine gains no
function and no option for this record.

**3. Two validations, and all of either one's findings in one answer.**

*Static*, against the two machines, before any execution is read: every
source id in `states`, `drop` and `history` is a state of the from chart;
every target id is a state of the to chart; no source id appears twice across
`states`, `drop` and `history`; a history state maps only to a history state;
every invocation's from ordinal is in range of its from state's `<invoke>`
children and its to ordinal in range of its to state's; no two invocations
share a source or a target; and the two machines carry the identities whose
content hashes the plan names. The static validation reads the two compiled
machines and nothing else.

*Against the execution*, at apply, under the execution's lock: the
execution's stored content hash is the plan's `from`; the execution is not in
a terminal status; `Position.export/1` answers, which means the position is
quiescent and every state in it is nameable; every state in the exported
`configuration`, `entered_states`, `states_to_invoke` and `history_values` is
mapped (by name or by the same-id default) or dropped, and none is unmapped; every active invocation
maps to a key whose state is not dropped, and whose ordinal - named in
`invocations` or kept by the same-ordinal default - is in range of that
to state's `<invoke>` children, because `Position.import/2` checks state ids
and value shapes and never an ordinal; no two invocation keys in the
transformed position coincide, whether named in `invocations` or kept by the
same-ordinal default, because one `active_invocations` entry would otherwise
silently overwrite the other; the datamodel operations apply in
order (an `add` of a key already present, a `rename` from an absent key or
onto a present one, and a `remove` of an absent key each refuse); decision
6's timer rule holds; decision 7's child rule holds; and `Position.import/2`
on the to machine answers a position.

The validations check that every state id and every invocation ordinal in the
position resolves. They do not
check that the resulting configuration is a legal configuration of the to
chart; see "What this record does not decide".

**4. Whole or nothing, in terms the adapters can meet, and `on_failure:
:refuse | :park`.** A migration either re-pins the execution completely or
leaves its chart, its identity and its position as they were; the status
write under `:park`, below, is the one exception. The mechanism is ordering, not a
transaction the adapters do not all have: both validations and the full
transform complete before the first write; the one write that migrates is a
single `Storage.update_execution/5` with the imported position on the to
machine, which replaces the identity, the content hash and the position blob
together; and nothing that can fail follows it inside the lock. A host saves
the to chart through `save_chart/3` before it migrates, as it does before
`create/4`, and a chart saved ahead of a refused migration is an unused
content-addressed row that changes no execution. If an implementation ever
places a write before a step that can still fail, that step's failure rolls
the write back explicitly, because a returned `{:error, _}` commits inside
the Ecto adapter's lock (Context). A to hash that ADR-0012 has tombstoned is
refused with ADR-0012's retired arm, before any write, as `create/4` refuses
one. There is no separate lease. `migrate/4` takes the same `serialization:`
option every `Executions` entry point takes, defaulting as they do, and
calls that strategy's `with_execution/3` directly; it does not go through
`serialized/5`, whose `entry()` is ADR-0010's closed door vocabulary
(decision 5). A host passes the strategy it passes to its steps, and the
two are then mutually exclusive on the execution.

`on_failure:` chooses what a refusal of the second validation does to the
execution. `:refuse`, the default, returns the refusal and writes nothing. A
failed migration may instead park the execution in the status ADR-0014
decides, under `:park`; that is the one write a refusal can cause, it
touches no blob, and the position stays on the from chart. `:park` parks
only an execution that is not in a terminal status and is stored on the
plan's `from` hash. A refusal because the execution is terminal, or because
it is stored on another chart than the plan's `from`, writes nothing under
either value, and so does a refusal that comes before the execution is
read - a static fault, a lock that could not be taken - and so does the
refusal of a to hash ADR-0012 has tombstoned, because that refusal concerns
the plan and not this execution. A successful migration writes the execution back at
`:active`.

**5. No stored trace entry: one telemetry event on success, and the answer
carries the same facts.** There is no per-execution trace to write to, and
the input log is not one: a migration delivers no event, so ADR-0010's door
vocabulary does not grow and no input-log row is written. A successful
migration emits one event, `[:statifier_persistence, :execution, :migrated]`,
with `system_time` as its measurement and `execution_id`,
`from_content_hash`, `to_content_hash` and `dropped` as its metadata, and
its success answer carries the from and to hashes beside the migrated
execution. `dropped` lists the dropped states that were in the execution's
configuration. A drop is an operator exit and is never recorded as an
authored transition: no `onexit` content executes, no transition is taken and
no event is raised for it. A migration is not a step and takes no step span.

**6. Timers: a mapped timer keeps its deadline, and a migration never
proceeds blind to them.** This package stores no timer and changes none; a pending delayed
send stays in the host's queue with the deadline it was given, and a
migration that maps the state around it leaves it there - that is what
`keep_mapped: true` states, and it is the only value this format admits.
Because the counters are carried (decision 2), a send id the migrated
execution generates (`send_counter`) and a timer ordinal it mints
(`timer_counter`) cannot collide with one a surviving timer holds. An
author-written send id is not protected by either counter: an id the to
chart writes by hand can still equal the id of a pending timer, and that is
the plan author's to check.

A state **could own a timer** when, in the from chart, a `<send>` with a
`delay` or a `delayexpr` appears anywhere in its `onentry`, its `onexit`,
the executable content of a transition it owns (its `<initial>` element's
transition and a history state's default transition included), or the
`<finalize>` of any of its `<invoke>`s, the bodies of nested `<if>` and
`<foreach>` included. That is the engine's whole reach for executable
content: the owner of a content block is one of `{:onentry, ...}`,
`{:onexit, ...}`, `{:transition, ...}` or `{:finalize, state_index,
invoke_index}` (`deps/statifier/lib/statifier/machine/content.ex`,
`@type owner`, statifier 2.6.0), and a `<send>` inside `<finalize>`
compiles with a validator warning and still executes. The definition is static because a
count cannot say which state a pending timer came from and a delayed send is
not scoped to a state.

Pending timers are read through pin sources the host supplies in `opts`,
asked for the one execution through `PinSource.collect/3`. A plan that leaves
a state that could own a timer unmapped, while any source counts a pending
timer for the execution, is refused unless the plan drops that state. With no
source supplied, **any plan that leaves unmapped or drops a state that could
own a timer is refused, and the refusal names the missing source** - fail
closed. A source that cannot answer refuses the migration the same way it
refuses a retirement. A plan that maps every state that could own a timer
needs no source.

**7. Children are untouched.** A child's linkage pins the child's own chart,
and execution metadata is write-once, so a parent's migration rewrites
nothing in any child: not its row, not its linkage, not its position. What a
parent's migration changes is the parent's `active_invocations` keys, through
`invocations`; the invocation ids those keys carry cross unchanged. Every
active invocation must map (decision 3), and if any live child's linkage
would no longer resolve against the migrated parent - its invocation id no
longer named by an active invocation - the migration is refused whole.
Migrating a child, or a tree, is not decided here.

**8. Three owners.** The engine (statifier-ex) owns the export, the import,
the chart diff and the position predicate. This package owns the plan, both
validations, `migrate/4` and the parked quarantine. statifier_blocks
generates a mapping between two revisions of one document as plain maps in
this record's field names - `states`, `history`, `invocations` - and takes
no dependency on this package; statifier_oban owns a pin source over its own
timer jobs. `migrate/4` does not call the engine's position predicate.

**9. `Executions.migrate/4` is the one sanctioned re-pin, and it goes
through the identity guard rather than around it.** Its arguments are the
store, the execution id, the plan and options; the two compiled machines
arrive in the options, because a chart blob is opaque to this package
(ADR-0003 decision 1) and this package cannot build a machine from one. It
loads the position with the from machine through
`Storage.load_execution_position/3`, so the guard checks the stored identity
against the from machine exactly as it does for a step. It re-pins with the
single `update_execution/5` of decision 4, which derives the new identity and
content hash from the imported position's own machine. After it, a load with
the to machine passes the guard and a load with the from machine is refused
with the guard's `identity_mismatch` arm. The guard itself is untouched: it
compares what it always compared, and the migration changes, in one write,
the thing it compares against. `step/5` cannot re-pin, because it loads and
writes with the same guarded machine. Nothing in this package calls
`migrate/4`: saving a chart, creating an execution and stepping one never
migrate anything, and a host that wants every execution on a hash moved
writes that sweep itself, over the drained query
(`Executions.executions_on/2`, ADR-0012 decision 3) and one `migrate/4` per
execution.

## Consequences

**This record's text binds the implementing code.** `migrate/4` implements
decisions 2 through 9 and the plan module implements decisions 1 and 3's
static half; each cites the decision it implements. The migrate cases prove
the library hold landing in `ready_for_pickup` on the new hash with its
counters carried, and each refusal leaving the stored chart, identity and
position unchanged - with the status write under `on_failure: :park` the one
exception decision 4 names - over both shipped adapters. The static definition in decision 6 is a rule;
the test that enumerates it over compiled charts is the timer case's, and
this record claims no complete list of the family's timer-owning shapes.

**Pin-and-drain becomes operable.** A host that retires old charts now has
two ways to empty one: wait for its executions to finish, or migrate them.
Either way the drained query (`docs/adr/0012-retention-and-retirement.md`,
decision 3) is how it sees the hash empty, and `Executions.retire_chart/4`
(same record, decision 5) is how it retires it. This record does not amend
ADR-0012.

**The identity guard's reading of `identity_mismatch` gains a second
remedy.** ADR-0003 decision 4 says the arm carries both identities because
the caller's next move may be to "migrate the position"; this record is that
move, for executions (`docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`).

**Telemetry gains one event.** `[:statifier_persistence, :execution,
:migrated]` joins the family ADR-0009 names, and `docs/telemetry.md` gains
its row with the code that emits it.

**The other two records this design rests on are in progress.** statifier-ex's
record of the chart diff and the position predicate is not on that
repository's `main` as this is written, and is cited here by repository and
subject, not by number. statifier_blocks' mapping is an Amendment to its
ADR-0004 (`docs/adr/0004-compiler-provenance.md` in that repository, cited
here as sb-ADR-0004), which is on its `main`; the Amendment is not yet, and
is cited by subject.

### What this record does not decide

- Migration at publish time, in any form. Nothing migrates an execution
  because a chart was saved, created against or published.
- Migrating a child or a tree of executions.
- Datamodel operations beyond `add`, `rename` and `remove` on top-level
  keys, and any computed value.
- Where a host stores its plans.
- Whether a migrated configuration is a legal configuration of the to chart
  beyond every part of it resolving; that belongs with the engine's position
  predicate, which `migrate/4` does not call.
- Cancelling or rescheduling a mapped timer (`keep_mapped: false`).
- What the parked status is, what it admits and how it is listed: that is
  ADR-0014's.
- Telemetry for a refused or parked migration, and how a replay of the input
  log (ADR-0010 decision 8, built nowhere) treats an execution whose chart
  changed partway through its log.
