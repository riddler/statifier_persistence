# ADR-0013: The migration plan: one plan per pair of chart hashes, a transform over the engine's export applied by its import, two validations, whole or nothing, a telemetry event and no stored trace, timers read through host pin sources and refused without one, children untouched, three owners

Status: accepted (2026-09-23, sp-bn0; proposed the same day and accepted once
the code beads had landed against it: sp-mz3 the plan struct, sp-7a9
`Executions.migrate/4`, sp-7cj children untouched, sp-pq4 timers, sp-9tj4 the
migrate cases)

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

## Amendment (2026-09-23, sp-pq4): a missing pin source is refused before the execution is read, and neither it nor a source that cannot answer parks

Status of this amendment: proposed (2026-09-23, sp-pq4). The record above
stays proposed; this amendment is proposed until the operator accepts it.

Read as written, decisions 3 and 4 park every refusal decision 6 makes:
decision 3 places decision 6's timer rule inside the validation against
the execution, under the execution's lock, and decision 4 parks any refusal
of that validation under `on_failure: :park`. That answer lets a host's
sweep over a hash, with a plan that drops a state that could own a timer
and no pin source, park every execution it touches. This amendment changes
the answer for two of decision 6's three refusals.

**It amends decision 3.** The no-source half of decision 6 leaves the
validation against the execution. Whether a plan leaves unmapped or drops a
state that could own a timer is a question about the plan and the two
machines alone, because decision 6's definition is static over the from
chart, so it is decided before the execution is read: with no source
supplied, such a plan is refused with `{:error, {:no_pin_source, states}}`,
not as a finding of `{:migration_refused, findings}`
(`lib/statifier_persistence/executions.ex`, `timer_check/4`, read at
`dce34f9`). The half that reads the sources stays in the validation against
the execution: a plan that leaves such a state unmapped while a source
counts a pending timer for the execution is refused with a finding of that
validation, and parks under `:park` as decision 4 says.

**It amends decision 4.** Its list of refusals that write nothing under
either `on_failure:` value gains two entries: a missing pin source, as
above, and a pin source that cannot answer. The second refuses the
migration as it refuses a retirement, with the same top-level arm,
`{:error, {:pin_source_failed, {module, reason}}}`
(`lib/statifier_persistence/executions.ex`, `ask_pin_sources/3`, read at
`e998c95`); a source that did not answer has reported nothing about the
execution, and parking it on that account would quarantine an execution
for a fault in the host's queue.

ADR-0014's "A parked hold" walk parks the hold under the first plan only
when the host supplies a pin source; with none, that plan is refused before
the execution is read and parks nothing.

**A state with no id is unmapped by every plan.** Decision 1 maps a state
the plan does not name to the state of the same id in the to chart; a state
compiled without an author-written id has no id to match and cannot be
named in `states` or `drop`. When such a state could own a timer, decision
6 counts it as unmapped, and a refusal names it by its index in the from
machine (`lib/statifier_persistence/migration/transform.ex`,
`timer_states/3`, read at `dce34f9`).

## Amendment (2026-09-23, sp-i5ha): a kept or moved invocation keeps its `<invoke>` element and lands in the transformed configuration, and the transformed configuration must be legal

Status of this amendment: proposed (2026-09-23, sp-i5ha). The record above
is accepted; this amendment is proposed until the operator accepts it, and
the 2026-09-23 sp-pq4 Amendment above keeps its own status.

A migration is whole or it did not happen, and a whole migration must not
be wrong: `migrate/4` must never answer `:ok` on a transformed position the
engine would run incorrectly. Decision 3 checks that every state id and
every invocation ordinal in the transformed position resolves, and its last
paragraph and "What this record does not decide" leave the legality of the
migrated configuration to the engine's position predicate. Resolving is not
enough. Each of the three worked examples below resolves in full, and
`migrate/4` answers `:ok` on each today.

**It amends decision 3.** The validation against the execution gains three
findings. Each is a finding of that validation, so each arrives inside
`{:migration_refused, findings}` with every other finding in one answer,
refuses the migration whole before any write, and parks the execution under
`on_failure: :park` exactly as decision 4 parks decision 3's other findings
(`lib/statifier_persistence/executions.ex`, `refuse/4`, read at `21519fc`).
`t:migration_finding/0` gains the three arms named below.

1. **An invocation keeps its `<invoke>` element:
   `{:invocation_element_changed, {from_state_id, from_ordinal},
   {to_state_id, to_ordinal}}`.** An active invocation kept by the
   same-ordinal default, or moved through `invocations`, whose target
   `<invoke>` element is not the element it was started from, is refused.
   Today the default checks only that the ordinal is in range of the to
   state's `<invoke>` children
   (`lib/statifier_persistence/migration/transform.ex`,
   `default_invocation/4`, read at `21519fc`), and a named move is taken as
   written (same file, `map_invocation/4`). The comparison runs only on a
   target that exists: an ordinal out of range stays decision 3's
   `invocation_out_of_range` finding alone.

   **The identity rule.** The source element is the from state's `<invoke>`
   at the from ordinal in the from machine; the target element is the to
   state's `<invoke>` at the to ordinal in the to machine. When the source
   element authors an `id`, the target element must author the same `id`.
   When the source element authors none, the target element must author
   none, and the two elements' source slices must be byte-equal (each
   element's `location` sliced over its machine's source, the slice covering
   the element and everything inside it). The id is the rule where it
   exists because an authored id IS the invocation id the live child was
   started under and answers to (`Statifier.Interpreter`,
   `generate_invoke_id/3`, statifier 2.6.0): the same id on the new side is
   the same element in the author's own name, and the element's content -
   its parameters, its `<finalize>` - may change across revisions as the new
   chart's behaviour, as any other content does. The slice is the rule
   where there is no id because nothing else names an unnamed element: a
   byte-equal slice is the only identity a machine carries for it apart
   from its position, and position is exactly what the default trusts
   today. The slice rule fails closed - an unnamed element whose text
   changed cannot be migrated while it is live - and an author who wants
   that edit to migrate gives the element an `id`. Position alone is never
   the rule.

2. **An invocation lands in the transformed configuration:
   `{:invocation_outside_configuration, {from_state_id, from_ordinal},
   {to_state_id, to_ordinal}}`.** An active invocation kept by the default
   or moved through `invocations` whose target state is not in the
   transformed `configuration` is refused. The engine reaches a live
   invocation only through a state it holds: the finalize and autoforward
   pass walks the configuration (`Statifier.Interpreter`,
   `apply_invoke_passes/2`, statifier 2.6.0), and an invocation is
   cancelled when its state exits
   (`Statifier.Interpreter.ExitEntry`, `cancel_invocations_for_state/2`,
   statifier 2.6.0). An invocation left on a state outside the
   configuration is reached by neither, so its child outlives the parent's
   completion. This extends decision 7: a live child's invocation id must
   not only stay named by an active invocation, it must be named on a state
   the parent holds.

3. **The transformed configuration is legal:
   `{:illegal_configuration, state_ids}`.** The transformed `configuration`,
   resolved in the to machine with the root added (the root that
   `Position.export/1` drops and `Position.import/2` re-adds, statifier
   2.6.0, `import/2`), must be a legal configuration under SCXML spec 3.11:
   every compound state in it has exactly one child state in it (the root
   included, which is the root rule); every parallel state in it has every
   one of its child states in it; every atomic state in it has every proper
   ancestor in it; and no history pseudo-state is in it. `state_ids` is the
   transformed configuration, sorted, so a host sees what the plan would
   have produced. The check runs in the same pass as the other findings, so
   a plan that leaves a state unmapped may answer both the
   `unmapped_state` finding and the illegal configuration it leaves.

   The check is **private to this package**. It needs only public
   functions of `Statifier.Machine` - `index/2`, `atomic?/2`, `parallel?/2`,
   `history?/2`, `child_states/2` (history children excluded) and
   `proper_ancestors/2` (statifier 2.6.0,
   `deps/statifier/lib/statifier/machine.ex`), and it asks nothing new of
   the engine. At statifier 2.6.0, the version
   `mix.lock` resolves, `Statifier.Position` has no legality function,
   public or private, and no `compatible_at?/3`; `Position.import/2` checks
   state ids and value shapes and no legality (`import/2`, statifier
   2.6.0). The `~> 2.6` requirement also admits statifier 2.8.0, where
   `Position.compatible_at?/3` is public and its legality helper is private
   (`lib/statifier/position.ex` in statifier-ex, `compatible_at?/3` and
   `legal_configuration?/2`, at `v2.8.0`, `a16c035`). This package calls
   neither, as decision 8 says of the predicate; the predicate answers a
   different question (whether an execution's own surface is unchanged),
   and legality is the one part of it a migration needs.

**It reverses the record's deferral of legality to the engine, for this
package.** Two sentences above are superseded by finding 3 and are left
as written. Decision 3's last paragraph: "They do not check that the
resulting configuration is a legal configuration of the to chart", with
its pointer onward. And the bullet under "What this record does not
decide": "Whether a migrated configuration is a legal configuration of the to chart
beyond every part of it resolving; that belongs with the engine's position
predicate, which `migrate/4` does not call." From this amendment the
validation against the execution checks that the migrated configuration is
a legal configuration of the to chart, by the rule of finding 3 and no
further, in this package and not in the engine. Decision 8's sentence
stands: `migrate/4` does not call the engine's position predicate. What
remains undecided: the legality of the recorded `history_values`, and
whether an unchanged surface at the position makes the migration behave as
the author meant - that is still the predicate's question, and
`migrate/4` still does not ask it.

**A host can observe each finding as a change.** A plan that answered
`:ok` before this amendment can now refuse, or park under `:park`, and
`t:migration_finding/0` gains three arms. Each code change that implements
a finding carries a changelog fragment written as a breaking change, and
says what a host does about it: name the invocation's move onto its own
element, move it onto a state the migrated configuration holds, or plan a
configuration the to chart can hold (map the dropped state, or drop its
whole region).

### Worked examples

All three are the library hold of the Context, and each answered
`:ok` at `21519fc` on statifier 2.6.0 (probed through
`StatifierPersistence.Migration.Transform`, `transform/5`, read at
`21519fc`; first found by probe through `migrate/4` on both shipped
adapters).

- **The kept notice on the slip's element (finding 1).** The hold waits in
  `awaiting_pickup` with its two invocations, the patron notice
  (`<invoke id="notice">`, ordinal 0) and the desk slip
  (`<invoke id="slip">`, ordinal 1). The next revision renames the state
  `ready_for_pickup` and prints the slip first, so its `<invoke>` children
  are `slip` then `notice`. The rename plan names no `invocations`. By the
  default, the invocation `notice` lands at `{ready_for_pickup, 0}`, the
  element authoring `id="slip"`, and would take that element's finalize
  and autoforward. Refused with `invocation_element_changed` for each of
  the two; the plan that names both moves, `awaiting_pickup` 0 onto
  `ready_for_pickup` 1 and 1 onto 0, migrates, because each lands on the
  element of its own id.
- **The notice moved off the configuration (finding 2).** A plan that maps
  every state to itself and moves the notice through `invocations` onto
  `stash` 0, a sibling of `awaiting_pickup` the hold is not in, whose one
  `<invoke>` also authors `id="notice"`, so finding 1 holds and finding 2
  alone refuses. The configuration stays
  `{hold, awaiting_pickup}` and the notice sits at `{stash, 0}`. On
  `hold.cancelled` the parent completes, and nothing cancels the notice:
  `stash` never exits because it was never entered. Refused with
  `invocation_outside_configuration`.
- **The dropped active leaf (finding 3).** The hold waits in `routing`, a
  child of the compound `hold`. A plan that drops `routing` leaves the
  configuration `{hold}`: a compound state with no active child, which the
  engine's import accepts. Refused with `illegal_configuration`. A drop of
  a whole region of a parallel - the parallel keeping its other regions -
  still migrates, because that configuration is legal.
