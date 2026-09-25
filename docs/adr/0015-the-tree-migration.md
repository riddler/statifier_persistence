# ADR-0015: The tree migration: one plan per node, every node validated before any is written, children first, one store unit across the tree, the parked tree, and a child's linkage pin that follows the child

Status: accepted (2026-09-23, sp-3l2a)

## Context

ADR-0013 moves one execution onto a newer chart, whole or not at all, and
leaves every durable child of it untouched: "a parent's migration rewrites
nothing in any child: not its row, not its linkage, not its position", and
"Migrating a child, or a tree, is not decided here" (ADR-0013 decision 7,
`docs/adr/0013-the-migration-plan.md`). ADR-0014 gives a refused migration
somewhere to wait, and repeats the gap: "Migrating a tree of executions
together - a parent and its durable children - is not decided"
(`docs/adr/0014-the-needs-migration-status.md`, decision 8). This record
decides it.

The rule does not change with the size of the thing moved. A migration is
whole or it did not happen, across a tree as across one execution: every
node the host asked to move lands on its new chart, or no node moves, and
no answer, event or stored row describes some nodes moved and others not.
Nothing migrates an execution because a chart was published, and nothing
here calls the engine's position predicate.

The four nouns keep their one job each. A **document** is the host's stable
name for a thing it authors; a **revision** is one saved edit of it; a
**chart** is the SCXML a revision emits, identified by its content hash; an
**execution** is pinned to one chart hash and re-pinned only by an explicit
migration. A tree of executions is a parent and the durable children it
invoked (ADR-0008), each an ordinary execution on its own chart.

### The case this record is written against

A library hold. The hold's execution waits in `awaiting_pickup`, and on
entering it the hold invoked a durable child: a pickup-notice execution,
which sent the patron a notice and now waits in `notice_sent` for the
patron's acknowledgement. Both documents are edited. In the hold document
`awaiting_pickup` becomes `ready_for_pickup`, as in ADR-0013's case; in the
pickup-notice document `notice_sent` is renamed `patron_notified`. The host
wants the waiting hold and its waiting notice on the new charts together:
the child on the new pickup-notice chart, still resolving against its
parent, and the hold on the new hold chart - or neither moved.

ADR-0013 alone cannot do it. `migrate/4` on the hold leaves the child on
the old pickup-notice chart. `migrate/4` on the child re-pins the child's
row but not its linkage, whose `content_hash` then names a chart the child
is no longer on. And two calls are two outcomes: the second can be refused
after the first has written.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`21519fc`**
("Accepts ADR-0013 and ADR-0014"), read 2026-09-23. Every code cite carries
that SHA and an anchor, because line numbers move and anchors do not.

- **A child's linkage pins the child's own chart, in a reserved metadata
  namespace.** `StatifierPersistence.Execution.Linkage` stores
  `parent_execution_id`, `invoke_id`, `child_index` and the mandatory
  `content_hash` under the reserved key `"statifier_persistence"`
  (`lib/statifier_persistence/execution/linkage.ex`, `@enforce_keys` and
  `reserved_key/0`, @21519fc); the hash is the child machine's own identity
  hash (ADR-0008 decision 2).
- **Execution metadata is write-once.** `c:StatifierPersistence.Storage.Adapter.update_execution/2`
  carries the stored `metadata` forward verbatim and ignores the field of
  the record it is given (`lib/statifier_persistence/storage/adapter.ex`,
  the `update_execution/2` callback doc, @21519fc), as ADR-0006 decision 1
  grants. No callback rewrites any metadata key after create.
- **The linkage pin pins a chart against retirement.** A durable child's
  linkage pin names a hash, and while the child's parent is `:active` or
  `:needs_migration` that hash is pinned whatever arm the child is in
  (ADR-0012 decision 1, as ADR-0014 decision 4 reads it); the Ecto adapter
  counts it in `child_pins/2` and the in-memory adapter in
  `pinned_child?/3` (`lib/statifier_persistence/storage/ecto.ex`,
  `child_pins/2`; `lib/statifier_persistence/storage/in_memory.ex`,
  `pinned_child?/3`, @21519fc). A child re-pinned without its linkage would
  go on pinning the chart it left.
- **The tree is read through the linkage.** `Executions.cascade_cancel/3`
  walks a tree by listing the executions whose linkage names a parent,
  `Linkage.parent_match/1` through `Storage.list_executions_by_metadata/2`,
  and descends through every child whatever its status
  (`lib/statifier_persistence/executions.ex`, `cascade_cancel/3` and
  `cancel_and_descend/3`, @21519fc). The tree is acyclic by construction: a
  child's execution id extends its parent's
  (`Linkage.child_execution_id/3`, @21519fc).
- **Exclusions are taken ancestor first, never the other way.** The
  cascade's doc states the lock order this package keeps: nothing holds a
  descendant's exclusion and then asks for an ancestor's, and a child
  releases its own before answering its parent (`executions.ex`,
  `cascade_cancel/3` doc, @21519fc). The single-child start creates the
  child inside the parent's exclusion (`lib/statifier_persistence/driver.ex`,
  the `{:start_child, _, _}` clause of the dispatch, @21519fc).
- **A fan-out child is created outside its parent's exclusion.**
  `Driver.start_child_at/6` creates each fan-out child from whatever job
  picks it up, after the parent's step has enqueued it (`driver.ex`,
  `start_child_at/6` doc, @21519fc). Holding a parent's exclusion does not
  stop a new child of it from appearing.
- **No existing callback writes several executions as one unit.**
  `c:lock_execution/3` excludes one execution id; the Ecto adapter wraps
  its function in one `repo.transaction/1`, so a function that returns
  `{:error, _}` commits what it wrote, and the in-memory adapter's lock is a
  mutex with no transaction (`storage/adapter.ex`, `lock_execution/3`
  callback doc; `storage/ecto.ex`, `lock_execution/3`, @21519fc; ADR-0013,
  Context). `c:update_execution/2` writes one execution. The one callback
  that is an atomic unit over more than one row is `c:retire_chart/3`,
  "one transaction on a database, one atomic state transition on an
  adapter without one", optional and declared by
  `c:supports_chart_retirement?/1` (`storage/adapter.ex`, both callback
  docs, @21519fc). And the cascade states the package's standing position
  for its own walk: "Cross-execution locking is the only way to make it
  atomic, and this package does not have it and does not want it"
  (`executions.ex`, `cascade_cancel/3` doc, @21519fc).
- **`migrate/4` is the one-execution move this record reuses.** Its
  validations, its timer rule and its park are
  `Executions.migrate/4` (`executions.ex`, `migrate/4`, `migrate_tail/6`
  and `migrate_loaded/6`, @21519fc) under ADR-0013 and every Amendment that
  record carries, and ADR-0014.

## Decision

**1. The command is `Executions.migrate_tree/4`, one ADR-0013 plan per
node.** `StatifierPersistence.Executions.migrate_tree/4` takes the store,
the root execution id, `plans` and options. `plans` is a map from execution
id to one ADR-0013 plan (`StatifierPersistence.Migration.Plan`); the same
plan may serve several nodes, since two children on one chart move by one
pair of hashes. Every compiled machine the plans name arrives in the
options, as `migrate/4`'s `from_machine:` and `to_machine:` do, under
`machines:`, a map from content
hash to compiled machine that holds the `from` and `to` machine of every
plan; a plan whose machine is absent is a static refusal. The options also
take `pin_sources:`, `on_failure:` and `serialization:` with `migrate/4`'s
meanings and defaults.

A node present in `plans` is moved by its plan. A node absent from `plans`
is left untouched - its row, its linkage and its position - exactly as
ADR-0013 decision 7 leaves a child of a migrated parent; if it is live (not
in a terminal status), it must still resolve against its parent as that
parent will stand after the tree moves, or the tree is refused. So a host
that names only the root migrates the root as `migrate/4` would, and a host
that names every node moves the whole tree. A child migrated on its own is
migrated by this command with the child as the root. An id in `plans` that
is not a node of the tree rooted at the root is refused before any write.

`migrate/4` is unchanged by this record. The command is the only place a
child's linkage pin is rewritten (decision 3 and ADR-0008's 2026-09-23
Amendment).

**2. The walk reads the tree through the linkage, and applies children
first, the root last.** The tree is the root and every execution reached by
listing the executions whose linkage names a parent, from the root down, as
the cascade cancel lists them (`Linkage.parent_match/1` through
`Storage.list_executions_by_metadata/2`), through every child whatever its
status. An adapter that cannot list by metadata cannot read a tree, and the
command answers the listing's own `{:error, :child_listing_unsupported}`
before anything is written (`lib/statifier_persistence/storage.ex`,
`list_executions_by_metadata/2`, @21519fc).

The exclusions follow the order this package already keeps: the command
takes, through the serialization strategy's `with_execution/3`, the
exclusion of every node `plans` names, each ancestor before its
descendants and siblings in ascending execution id, and holds them all
until the unit of decision 3 has returned. A node absent from `plans` is
read and never locked, as `migrate/4` takes no child's lock: what it must
satisfy is fixed by its linkage, which is write-once, and by its parent's
position, whose exclusion the command holds when the parent is named. The
tree is listed again once every exclusion is held, and the nodes named in
`plans` are checked against that second listing.

Inside the exclusions, validation and the write go children first and the
root last: every node's validation against the execution is taken leaves
up, the answer lists the nodes in that order, and the unit writes them in
that order. Inside one unit the write order is not observable by any
reader, and this record does not rest anything on it; the order is the
order a host reads the answer and the events in.

A fan-out child created by `Driver.start_child_at/6` while the command
holds its exclusions is outside its parent's exclusion by design (Context).
It is not a node the plans name, so it is a node absent from `plans`: it
links to its parent by invocation id, and it resolves against the moved
parent for the same reason every absent node must, because the parent's
validation required that invocation to map (ADR-0013 decisions 3 and 7).

**3. All or nothing across the tree, in one store unit, through one new
optional adapter callback.** The command validates every node the plans
name - ADR-0013 decision 3's static validation and its validation against
the execution, with every Amendment ADR-0013 carries, reused unchanged and
not restated here - and every node absent from `plans` against decision 1's
resolve rule, before any node is written. One refusal anywhere refuses the
tree, and the answer carries every node's refusal at once.

The existing callbacks cannot make N writes one unit. Each
`c:update_execution/2` is one execution; holding N exclusions does not undo
a returned error on the Ecto adapter and there is no transaction at all on
the in-memory one (Context); and no callback can rewrite a linkage pin,
because metadata is write-once. Ordering alone - validate everything, then
write - is what ADR-0013 decision 4 uses for one write, and it does not
extend to N writes, since the second write can fail after the first has
landed. So this record decides a new optional callback:

- `c:StatifierPersistence.Storage.Adapter.supports_tree_migration?/1`, a
  declaration in the shape `c:supports_chart_retirement?/1` has; an adapter
  that does not export it and answer `true` makes `migrate_tree/4` refuse
  at open with `{:error, :tree_migration_unsupported}`, before any read and
  before any write.
- `c:StatifierPersistence.Storage.Adapter.write_tree_migration/2`, taking
  the adapter's options and a list of per-execution writes, and answering
  `:ok` having written every one of them or `{:error, reason}` having
  written none. One transaction on a database, one atomic state transition
  on an adapter without one - the unit `c:retire_chart/3` already asks
  for. An adapter reached inside an enclosing transaction (the Ecto
  adapter's lock is one) rolls that transaction back rather than returning
  an error that would commit it.

Each write in the list is one of two kinds. A **re-pin** carries the
execution record `migrate/4`'s one write would carry - the identity, the
content hash and the position blob derived from the imported position on
the to machine, the status `:active`, a `nil` failure - and, for a node
that carries a linkage, that node's new `content_hash` for its linkage pin.
The callback writes those fields, rewrites the linkage's `content_hash` to
the one given and nothing else under the reserved key, and carries every
other metadata key and the outcome forward verbatim, as
`c:update_execution/2` does. A **park** carries only the execution id and
writes the status `:needs_migration` with a `nil` failure, carrying every
other field forward, as `Storage.update_execution_status/4` does. Both
shipped adapters implement the pair.

`migrate_tree/4` calls `c:write_tree_migration/2` once, inside every
exclusion of decision 2, after every validation and every transform has
answered, and nothing that can fail follows it. The cascade cancel is
unchanged by this record and stays idempotent and resumable rather than
atomic; this record makes one operation hold several exclusions at once, in
the ancestor-first order the cascade's doc fixes, and gives that one
operation a unit. It does not make child creation transactional.

**4. `on_failure: :refuse | :park` applies to the whole tree.** A tree
refused under `:refuse`, the default, writes nothing. Under `:park`, the
tree parks only when every refusal the command found is of a kind ADR-0013
decision 4 parks for its own node - a refusal of the validation against the
execution, on a node that is not terminal and is stored on its plan's
`from` hash - or a finding of decision 1's resolve rule, which is about the
parent's transformed position and parks as ADR-0013 decision 7's child
rule does. Then every node `plans` names parks, in one call to the
unit, whether its own validation refused or not: a node whose plan would
have applied is still a node the host has decided to move with the rest,
and ADR-0014's reason for the arm - that nothing steps an execution forward
on a chart its host has already decided to move it off - holds for it. A
node absent from `plans` is not parked. If any refusal is of a kind that
parks nothing for one execution - a static fault, a missing machine or pin
source, a pin source that did not answer, a tombstoned `to` hash, a
terminal node, a node on another chart than its plan's `from`, an id in
`plans` outside the tree, a lock that could not be taken, an adapter
without the unit - the tree writes nothing under either value.

This record therefore adds a second way into ADR-0014's arm. ADR-0014
decision 1 says the arm is reached only by `migrate/4` under `:park`;
under this record it is also reached by `migrate_tree/4` under `:park`, by
the rule above, and by nothing else. Everything else ADR-0014 decides of
the arm holds for a parked node: it is not terminal, a delivery to it is
refused whole with nothing appended and the redelivery the host's, it pins
its chart, and it is counted under its own key.

**A parked tree is left the ways ADR-0014 decision 3 names, per node or
together.** A corrected set of plans handed to `migrate_tree/4` moves it,
since a parked node is migrated as an `:active` one is; a refused set
parks again, writing the arm the nodes already hold. `Executions.unpark/3`
puts one node back to `:active` on the chart it was already pinned to; a
host that unparks a parked tree unparks each node, and every node it has
unparked is on its own old chart and was never moved, so an interrupted
unpark leaves no node migrated. A corrected plan for part of the parked
tree is a tree whose other nodes are absent from `plans`: they stay parked
and must resolve as decision 1 says.

**5. What a tree migration reports: ADR-0013's event, once per node moved,
after the unit.** Nothing is stored as a trace, and no input-log row is
written, for the tree or for any node (ADR-0013 decision 5). When the unit
has returned `:ok` and every exclusion has been released, the command
emits one `[:statifier_persistence, :execution, :migrated]` event per
re-pinned node, children first and the root last, each with the
measurement and metadata ADR-0013 decision 5 names for that node; the
event gains no key. A refused or parked tree emits none, as a refused or
parked `migrate/4` emits none. The success answer is
`{:ok, moved}`, `moved` the list of `{execution, migrated}` pairs in the
same order, each `migrated` the facts `migrate/4` answers for one node. A
refusal is `{:error, {:tree_refused, refusals}}`, `refusals` a map from
execution id to that node's refusal in `migrate/4`'s terms, or the
tree-level arm by itself when the refusal is not about one node (the
unsupported adapter, an id outside the tree, a lock that could not be
taken). A park answers `{:parked, {:tree_refused, refusals}}`.

**6. The timer and child-answer rules of ADR-0013 and ADR-0014 hold per
node.** Each node's plan meets ADR-0013 decision 6 as amended on its own:
a plan that leaves unmapped or drops a state of its from chart that could
own a timer, with no pin source supplied, refuses the tree before any
execution is read; the sources are asked under the exclusions for each
such node, with that node's plan's `from` hash and that node's execution
id; a source that does not answer refuses the tree and parks nothing. A
mapped timer keeps its deadline in the host's queue, node by node. ADR-0014
holds per node too: a delivery to a parked node, a child's answer to a
parked parent among them, is refused whole and is the host's to redeliver.

### A tree moved

The host saves both new charts, then calls `migrate_tree/4` with the
hold's id as the root, two plans - the hold's (`awaiting_pickup` to
`ready_for_pickup`) and the pickup-notice's (`notice_sent` to
`patron_notified`) - and the four machines. Both plans map every state
that could own a timer, so no pin source is needed. The command lists the
tree (the hold, and the pickup-notice child its linkage names), takes the
hold's exclusion and then the child's, lists the tree again, validates the
child and then the hold, and hands the unit two re-pins: the child onto the
new pickup-notice chart in `patron_notified`, its linkage pin rewritten to
that chart's hash, then the hold onto the new hold chart in
`ready_for_pickup`, its `<invoke>` kept under the mapped state by the
same-ordinal default so the child still resolves. Two `migrated` events
follow, the child's then the hold's. Neither old chart is pinned by this
tree any more - not by a row, and not by the child's linkage - so
`executions_on/2` counts nothing of it on either old hash, and the patron's
acknowledgement, delivered next, steps the child on its new chart.

Had the host's first pickup-notice plan left `notice_sent` unmapped, the
child's validation would have refused. Under `:refuse` nothing is written,
the hold included, though its own plan applied. Under `:park` both nodes
park, both still on their old charts; the acknowledgement delivered while
the child waits parked is refused whole and redelivered by the host once a
corrected pair of plans has moved the tree.

Had the host named only the hold, the child would stay untouched on the
old pickup-notice chart, resolving against the moved hold through its
invocation id, which is what `migrate/4` on the hold does today.

## Consequences

**This record's text binds the implementing code.** The code bead builds
`migrate_tree/4`, the two optional callbacks on both shipped adapters and
the storage conformance cases for the unit, and each cites the decision it
implements. The tree cases prove the library hold and its pickup-notice
child landing together, and every refusal - one node's validation, a node
absent from `plans` that would not resolve, a tree-level refusal - leaving
every node's chart, identity, position and linkage unchanged, with the
park's status writes under `:park` the one exception decision 4 names,
over both shipped adapters.

**A child's linkage pin becomes rewritable once, in one place.** ADR-0008's
2026-09-23 Amendment records the one sanctioned rewrite. Host metadata stays
write-once: the rewrite touches one package-owned key under the reserved
namespace, so ADR-0006's reopener - "metadata needing to be mutable after
create" - is not pulled for anything a host wrote.

**The retirement counts follow the move.** Because the pin follows the
child, a tree moved off two charts leaves both drained, and ADR-0012's
retirement proceeds on them without a change to ADR-0012.

**ADR-0014's single way into the arm becomes two.** Decision 4 widens
ADR-0014 decision 1's "reached only by `migrate/4`"; ADR-0014's text is
not edited by this record.

**The adapter behaviour gains an optional pair.** An adapter outside this
package that does not declare it sees no behaviour change beyond
`migrate_tree/4` refusing at open; no schema version is needed, since a
re-pin writes existing columns and the pin lives in the existing metadata
column.

**Telemetry gains no event.** `docs/telemetry.md`'s row for
`[:statifier_persistence, :execution, :migrated]` gains `migrate_tree/4` as
a second emitter, with the code that emits it.

### What this record does not decide

- Migration at publish time, in any form. Nothing migrates an execution, a
  child or a tree because a chart was saved, created against or published.
- Datamodel operations beyond ADR-0013's `add`, `rename` and `remove` on
  top-level keys.
- The automatic child-to-parent answer to a parked parent: the answer is
  refused whole (decision 6), and what the answering side does with the
  refusal is its own question.
- Whether `migrate/4` refuses, or re-routes, an execution that carries a
  linkage: it re-pins such an execution's row and leaves its pin, and this
  record moves a child through `migrate_tree/4` instead.
- A tree-level telemetry event, and telemetry for a refused or parked tree.
- Whether a migrated configuration is a legal configuration of its to chart
  beyond what ADR-0013 and its Amendments decide for one execution; this
  command adds no check of its own there and calls no engine predicate.
- Where a host stores its plans, and how it builds one plan per node.

## Note (2026-09-23, sp-y3hj): the spellings the code half gave to shapes the decisions describe, and one reading of decision 1

Pure addition: nothing above is edited, and this Note decides nothing the
record did not. It names what the code that implements the record
(`StatifierPersistence.Executions.migrate_tree/4` and the two optional
callbacks, landed with this Note) answers where a decision describes a
shape without spelling it. Every cite is by anchor, in that change.

- **A missing machine.** A plan whose `from` or `to` hash has no machine
  under `machines:` (decision 1) is refused, under that node's id, as
  `{:machine_missing, content_hash}`; it is a static refusal and parks
  nothing (decision 4). `t:StatifierPersistence.Executions.tree_refusal/0`.
- **The resolve rule's refusal.** A live node absent from `plans` that
  would no longer resolve (decision 1) is refused, under its own id, as
  `{:child_unresolved, parent_execution_id, invoke_id}`, and it parks the
  named nodes as decision 4 says. The rule is checked for such a node
  whose parent `plans` names: a parent that is not moved stands as it
  stood, and the node resolves against it as it did before the call.
  `unresolved_children/3` in `executions.ex`.
- **The tree-level arms.** Decision 5's "the tree-level arm by itself" is
  answered as `{:error, arm}`, without the `:tree_refused` wrapper, which
  is decision 3's own spelling for the unsupported adapter:
  `{:error, :tree_migration_unsupported}`, `{:error, {:not_in_tree,
  execution_ids}}`, and a listing, lock or unit refusal as the store or
  the serialization strategy answers it. On the Ecto adapter under the
  default serialization a unit that rolled back inside the lock's
  transaction reaches the caller as the lock's own
  `{:error, {:adapter, :rollback}}`, because decision 3 has the unit roll
  the enclosing transaction back rather than return an error inside it.
  `t:StatifierPersistence.Executions.migrate_tree_error/0`.
- **The unit's writes.** Decision 3's two kinds of write are
  `t:StatifierPersistence.Storage.Adapter.tree_write/0`:
  `{:repin, execution_record, linkage_content_hash | nil}` and
  `{:park, execution_id}`. The facade
  `StatifierPersistence.Storage.write_tree_migration/2` derives each
  re-pin's record from the imported machine state as
  `StatifierPersistence.Storage.update_execution/5` derives one, and
  `StatifierPersistence.Storage.tree_migration_supported?/1` is the
  declaration check, in the shape of `chart_retirement_supported?/1`.

## Note (2026-09-23, sp-o2ev): accepted, with decisions 5 and 1 read as the sp-y3hj Note spells them

The operator accepted this record on 2026-09-23, after the code that
implements it shipped in statifier_persistence 0.15.0 (tag `v0.15.0`,
`ae9c855`). The status line at the top flips in place from proposed to
accepted, and no other line of the record changes. Every cite below was
read on `main` at `ae9c855`.

What was re-read before the flip, decision by decision:

- **Decision 1.** `StatifierPersistence.Executions.migrate_tree/4` takes
  the store, the root id, `plans` and options, with `machines:`,
  `pin_sources:`, `on_failure:` and `serialization:`
  (`lib/statifier_persistence/executions.ex`, `migrate_tree/4`). A plan
  whose machine is absent is a static refusal (`tree_machine/2`), and an
  id in `plans` outside the tree is refused before any write
  (`check_named/2`). `migrate/4` keeps its behaviour: its checks are the
  functions the tree command shares (`plan_check/5`, `check_record/2`,
  `validate_execution/5`).
- **Decision 2.** The tree is read through `Linkage.parent_match/1` and
  `Storage.list_executions_by_metadata/2`, whatever each child's status
  (`read_tree/2`). The exclusions of the named nodes are taken ancestor
  first and siblings in ascending id, and held until the unit returns
  (`with_exclusions/4`). The tree is read again under them, and the named
  nodes are validated and written leaves up (`migrate_tree_locked/4`).
- **Decision 3.** The optional pair is on the behaviour
  (`lib/statifier_persistence/storage/adapter.ex`,
  `supports_tree_migration?/1` and `write_tree_migration/2`) and on both
  shipped adapters. The Ecto adapter rolls the enclosing transaction back
  on a refusal (`lib/statifier_persistence/storage/ecto.ex`,
  `write_tree_migration/2`). The in-memory adapter applies every write to
  one copy in one state transition (`storage/in_memory.ex`,
  `write_tree_migration/2`). An adapter without the pair is refused
  before any read (`check_tree_unit/1`). `cascade_cancel/3` is unchanged.
- **Decision 4.** The tree parks only on `{:migration_refused, _}` and
  `{:child_unresolved, _, _}` (`parks_tree?/1`). A park writes every
  named node in one unit and no absent node (`decide_tree/7`).
- **Decision 5.** One `[:statifier_persistence, :execution, :migrated]`
  event is emitted per re-pinned node, children first, after every
  exclusion is released (`tree_migrated/1`). A refused or parked tree
  emits none. `docs/telemetry.md` names `migrate_tree/4` as the event's
  second emitter.
- **Decision 6.** Each node's pin sources are asked under the exclusions
  with that node's plan's `from` hash and its own id
  (`validate_execution/5`).
- **Consequences.** The release adds no schema version. The storage
  conformance cases for the unit are in
  `StatifierPersistence.Testing.StorageConformance`.

**Decisions 5 and 1 are read as the sp-y3hj Note above states them**, as
the operator accepted it. Decision 5's "the tree-level arm by itself" is
answered unwrapped, as `{:error, arm}`, which is decision 3's own spelling
for the unsupported adapter (`t:migrate_tree_error/0`). Decision 1's
resolve rule is checked for a live node absent from `plans` whose parent
`plans` names; a node whose parent is not moved resolves as it did before
the call (`unresolved_children/3`). Both decisions stay as written, and the
sp-y3hj Note is how they are read.

## Amendment (2026-09-23, sp-4bnu): a unit that cannot land answers the adapter's own reason on both shipped adapters

Status of this amendment: accepted (2026-09-23, sp-4bnu). The record above
stays accepted; this amendment is proposed until the operator accepts it.

The sp-y3hj Note above records that on the Ecto adapter under the default
serialization a unit that rolled back inside the lock's transaction reaches
the caller as the lock's own `{:error, {:adapter, :rollback}}`, while the
in-memory adapter answers the unit's own reason. The same failed unit had
two answers, depending on the store. This amendment makes them one.

**It amends decision 3's sentence on an enclosing transaction.** An adapter
reached inside an enclosing transaction still never returns an error that
would commit the writes it had already made. A refusal it can decide before
its first write it returns as it is: nothing was written, so nothing is
rolled back and the enclosing transaction is left open. Only a failure after
a write rolls the enclosing transaction back. That is the shape the Ecto
adapter's `retire_chart/3` already has: its refusals write nothing and call
no `rollback/1` (`lib/statifier_persistence/storage/ecto.ex`,
`retire_chart/3`).

- **The Ecto adapter decides a missing execution before its first write.**
  It reads every execution the writes name, and one that is not stored is
  `{:error, :execution_not_found}` with nothing written
  (`lib/statifier_persistence/storage/ecto.ex`, `tree_rows_stored/2`). A
  write that still matches no row after that read rolls the transaction
  back, as before (`tree_writes/3`).
- **`migrate_tree/4` answers the same term on both shipped adapters.** A
  unit that names an execution that is not stored answers
  `{:error, :execution_not_found}` and writes no node, over the in-memory
  and the Ecto adapter alike
  (`test/statifier_persistence/executions_migrate_tree_test.exs`, "a
  failure inside the one unit writes no node and answers the unit's
  reason"). The term is one `t:StatifierPersistence.Executions.migrate_tree_error/0`
  already admits through `t:StatifierPersistence.Executions.error/0`; no
  error shape is added.
- **Inside a host's own transaction that refusal no longer aborts it.** The
  host's transaction stays open with nothing of the unit written, as it
  does after a refused `retire_chart/3`. A failure after a write still
  aborts it, and the caller then sees the enclosing transaction's own
  rollback.
- **The callback's contract says the same**
  (`lib/statifier_persistence/storage/adapter.ex`,
  `c:write_tree_migration/2`).

The sp-y3hj Note's sentence on `{:error, {:adapter, :rollback}}` stays as
written and is read as amended here: it now describes only a failure after
a write.

## Note (2026-09-24, sp-2wwq): the sp-4bnu Amendment is accepted

The 2026-09-23 sp-4bnu Amendment is accepted on 2026-09-24, under the
operator's standing grant to flip a record whose code has shipped. The code
that implements it shipped in statifier_persistence 0.15.1 (tag `v0.15.1`,
`3e25271`). That Amendment's own status line flips in place from proposed
to accepted, and the record above stays accepted. Its "this amendment is
proposed until the operator accepts it" is met here and stays as written.
Every cite below was read at `3e25271`, the tag, and again on `main` at
`183a849`, where none of them changed.

What was re-read before the flip:

- **Decision 3's sentence, as amended.** The Ecto adapter's
  `write_tree_migration/2` reads every named execution first and answers
  `{:error, :execution_not_found}` with nothing written and no rollback
  (`lib/statifier_persistence/storage/ecto.ex`, `tree_rows_stored/2`). A
  write that still matches no row rolls back (`tree_writes/3`).
  `retire_chart/3` calls no `rollback/1` on a refusal.
- **Both shipped adapters.** "a failure inside the one unit writes no node
  and answers the unit's reason" in
  `test/statifier_persistence/executions_migrate_tree_test.exs` runs over
  the in-memory and the Ecto adapter and asserts
  `{:error, :execution_not_found}`. `t:StatifierPersistence.Executions.migrate_tree_error/0`
  admits the term through `t:StatifierPersistence.Executions.error/0`.
- **The callback.** `c:write_tree_migration/2`'s doc in
  `lib/statifier_persistence/storage/adapter.ex` says a refusal decided
  before the first write is returned as it is.

## Amendment (2026-09-24, sp-hpci): `migrate/4` refuses an execution that carries a linkage

Status of this amendment: proposed (2026-09-24, sp-hpci). The record above
stays accepted; this amendment is proposed until the operator accepts it.

"What this record does not decide" leaves open whether `migrate/4` refuses,
or re-routes, an execution that carries a linkage, and records that it
re-pins such an execution's row and leaves its pin. The row then walks one
chart while the pin names another, and the old chart stays pinned while
the parent is `:active` (ADR-0012 decision 1). The operator ruled on
2026-09-24 that `migrate/4` refuses. This amendment records that ruling
and amends decision 1's sentence "`migrate/4` is unchanged by this
record".

**`migrate/4` refuses an execution that carries a linkage, and moves
nothing.** Under the execution's exclusion, once the row is read, an
execution whose metadata `Linkage.from_metadata/1` reads as a linkage is
refused with `{:error, {:linked, execution}}`, `execution` the stored
execution. The check comes before the terminal and from-chart checks, so a
finished child answers the same refusal. Nothing is written: not the row,
not the pin, not the position. Its code is `check_unlinked/1` in
`lib/statifier_persistence/executions.ex`, landed with this amendment.

- **It parks nothing.** The refusal is of the kind that writes nothing
  under either `on_failure:` value, as a terminal execution is. ADR-0014's
  arm is still reached by a refusal of the validation against the
  execution, and a linked execution never reaches that validation.
- **It emits no event.** A refused `migrate/4` emits none (ADR-0013
  decision 5).
- **The reason names the command that moves a child.** The typedoc of
  `t:StatifierPersistence.Executions.migrate_error/0` says what
  `{:linked, execution}` means and names `migrate_tree/4` with the child as
  the root, which decision 1 already provides ("A child migrated on its own
  is migrated by this command with the child as the root"). That command
  rewrites the pin in the same unit as the row (decision 3; `linkage_pin/3`
  in `lib/statifier_persistence/executions.ex`, read at `d72c92e`).
- **A parent is not refused.** The linkage is stored on the child only
  (`lib/statifier_persistence/execution/linkage.ex`, the struct, read at
  `d72c92e`), so a parent with live children carries none, and ADR-0013
  decision 7 still governs `migrate/4` on it. An execution that is both a
  child and a parent carries a linkage and is refused.
- **`migrate_tree/4` is unchanged.** Its nodes are checked by
  `validate_node/3`, which does not ask the linkage check, so a child
  named in `plans` moves with its pin as decision 3 says.

**The error set grows.** `{:linked, Execution.t()}` is a new arm of
`t:StatifierPersistence.Executions.migrate_error/0`, so a host that matches
`migrate/4`'s refusals exhaustively needs a clause for it. It ships in a
minor with a Breaking changelog line. `t:StatifierPersistence.Executions.tree_refusal/0`
includes `migrate_error/0`, but `migrate_tree/4` never answers the arm.

The tests are in
`test/statifier_persistence/executions_migrate_children_test.exs`, under
"migrate/4 on the pickup child, which carries a linkage", over both shipped
adapters. `migrate/4` on the child answers `{:linked, execution}` under
`:refuse` and under `:park`, and neither the child's stored record nor its
parent's changes, and a finished child answers the same refusal.
`migrate_tree/4` with the child as the root moves the child, and its
linkage pin names the new chart.

Decision 1's sentence "`migrate/4` is unchanged by this record" stays as
written and is read as amended here. The "does not decide" entry on
`migrate/4` and a linkage stays too, and this amendment decides it.
