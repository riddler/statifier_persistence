# ADR-0008: A durable subchart's child is an ordinary run, linked by pinned metadata, started and answered across the async seam, and ended by a cascading cancel that retains

Status: accepted (2026-09-01; unqualified direction-agent
verdict; drafts the durable-subchart rulings recorded on sp-nt8 and its
mirror sb-2i04, 2026-08-31)

## Context

`statifier_blocks` ships the canonical subchart invoke handler
(`StatifierBlocks.Runtime.Subchart`). Its `start/2` is a pure
planning callback that resolves a document id and returns one
`{:start_child, %Invoke{}, {:invoke, invoke}}` instruction, and that
instruction has an executor clause in `Statifier.Session` and nowhere else.
In the durable world it lands in `StatifierPersistence.Driver`, which has
never had a clause for it: the reference embedder answers a durable
subchart with `{:error, {:durable_subchart_unsupported, type}}` rather than
pretending. That refusal is honest and it is also the whole gap.

Two things blocked closing it, and only one of them has moved. The first
was mechanical: a subchart does not complete in the breath that starts it,
and until ADR-0007 the `dispatch` fun had no arm for a call that answers
later and no public door to answer through. That record landed the
`:pending` arm, `Driver.done_invocation/5` and `failed_invocation/5`, and
`active_invocations` as the cancel-versus-completion race mechanism. The
second is the question this record answers: *where does the child live, and
what is it to the parent?*

That is a real question rather than an obvious one, because a durable
subchart has a shape nothing else in this package has. It is a second
position that has to advance on its own schedule, survive its own restarts,
and be reachable by a node that has never seen its parent. It has to be
findable from the parent when the parent is cancelled, and it has to be
able to name the parent when it finishes. It can nest. And a chart author
who writes a subchart inside a `foreach` expects N of them, which is a
different problem wearing the same clothes.

The scope was ruled before drafting. The ruling notes on sp-nt8
(2026-08-31, recorded identically on the `statifier_blocks` mirror sb-2i04)
decided the mechanism, the linkage, the cancel semantics, the refusal set,
nesting, and that fan-out is deliberately out. This record states those
decisions in this package's own vocabulary and works out what they cost; it
does not reopen them. Its sibling is `statifier_blocks` ADR-0008, *durable
subchart invoke handler shape and refusals* (bead sb-wxj6), which owns the
handler side of the same pair - what a handler that cannot be a pure
`start/2` looks like. Contract ownership splits the way it always has:
storage, linkage, and stepping here; handler shape there.

## Decision

**1. The child is an ordinary run.** There is no child-run record type, no
subclass of `StatifierPersistence.Run`, and no second table. A child is
created through `Runs.create/4` like anything else, carries its own
`run_id` (a host identity in ADR-0002 decision 1's category), is guarded by
the same content hash at every load (ADR-0003 decision 2), persists through
the same `Statifier.Position` encoding, and advances through ADR-0004
decision 3's loop in the order that record fixed. Nothing in the step loop
learns that a run has a parent. This is what keeps the feature from
becoming a second engine: everything the durable path already guarantees
about a run - restart safety, the identity guard, per-run serialization -
is inherited by children for free, and a child that outlives its parent's
process is not a special case to reason about.

**2. Linkage is run metadata, and the child's chart identity is pinned.**
A child run's `metadata` (ADR-0006) carries three values: the parent's
`run_id`, the invocation id the parent knows it by, and a pin of the
child's own chart identity. The parent side is `active_invocations`, whose
entry for that invocation carries the child's `run_id`. There is no join
table; the ruling notes admit one only if the plan's queries force it, and
the queries this record foresees - *find my child*, *find my parent* - are
both single-key reads that do not.

The pin is **mandatory**, which is the one place this record hardens an
existing convention into contract. An earlier operator ruling treated a recorded
child chart identity as demo provenance; here it is required, because a
child is resumed by whatever node picks it up and the only thing standing
between "resumed the workflow you started" and "resumed a different
workflow that happens to share an id" is a recorded identity to check
against. It is the same content hash `Statifier.Machine.identity/1`
produces and ADR-0003's guard refuses on, recorded a second time where the
parent-child relationship can see it.

This narrows ADR-0006 decision 1. That record said this package never reads
a metadata key to make a decision, and cascade cancel (decision 5) requires
exactly that. The narrowing is stated rather than smuggled: linkage keys
live in a **reserved, package-owned namespace** within `metadata`, this
package reads *only* those keys, and everything outside the namespace stays
as opaque as it was - never read, never validated beyond shape, never
merged into a blob. ADR-0006 decision 2 is untouched and still absolute:
these are identities (`run_id`, invocation id, a content hash) and never
personal data. The alternative - a first-class linkage column - was not
chosen because it would put a durable-subchart concept into every adapter's
required schema, including adapters serving hosts that will never start a
child; the reserved namespace costs an adapter nothing, since ADR-0006
decision 3 already requires metadata support or an honest refusal at open.

**3. `start_child` is a pending dispatch, and a child answers through
ADR-0007's public doors.** The `Driver` gains an executor clause for the
`{:start_child, invoke, {:invoke, invoke}}` tuple that
`StatifierBlocks.Runtime.Subchart` already emits. The tuple is not renamed
and not re-shaped: the in-memory and durable paths plan the same
instruction and differ only in who executes it, which is what makes a chart
portable between them. The clause creates the child run with its linkage
metadata, and then returns `:pending` under ADR-0007 decision 1 - the
parent reaches quiescence with the invocation live in `active_invocations`
and rests, holding no process, for as long as the child takes.

Completion re-enters through the doors that record already built. A child
that reaches a final state answers its parent with
`Driver.done_invocation/5`, carrying its donedata; a child that fails
permanently answers with `failed_invocation/5` and st-ADR-0068's
`:reason`/`:attempts`/`:detail` payload. There is no bespoke parent-child
channel, no direct message, and no shared process: the parent is stepped by
the same public function any asynchronous host would call, so a child run
is - from the parent's side - indistinguishable from an HTTP callback that
happened to be well behaved.

**4. The refusal set stays closed, and grows by at most one.** A durable
start that cannot proceed refuses with the same three reasons the in-memory
handler uses - `unknown_document`, `child_compile_findings`,
`cycle_refused` - plus at most one durable-only reason for the case that
only exists here, a child run that could not be created
(`child-run-creation-failed`; the exact spelling is the implementation
plan's, not this record's). Every refusal is stated on
`error.communication.invoke.<invoke id>` with a reason and a JSON-shaped
`detail`, which is the same door and the same payload shape as any other
permanent failure, so a chart's existing `on_error` transition catches a
durable refusal without knowing it was durable.

**5. Cancel cascades, retains, and is idempotent.** When a parent exits the
invoking state - a timeout being the ordinary case - the child is
cancelled, and so are that child's own children, recursively. Cancellation
does not delete: every run record and every position stays, and a cancelled
run takes a **distinct terminal status**, a fourth arm alongside ADR-0004
decision 2's `:active | :completed | :failed` (the word is the plan's to
pick). Retaining is the point - a cancelled subtree is the evidence of what
a timed-out workflow was doing when the deadline hit, and deleting it would
make the durable path worse at answering questions than the in-memory one.

A completion that arrives for a cancelled invocation is dropped, by
ADR-0007 decision 3's mechanism and no new one: the door reverse-looks-up
the invocation id in the parent's persisted `active_invocations` inside the
serialization strategy, does not find it, and returns `{:discarded, run}`.
This is where a durable subchart is different from an HTTP callback and
where the design has to be checked rather than argued, so two named
scenarios are hard acceptance criteria for the implementation, extending
ADR-0007's own `test/statifier_persistence/driver_restart_race_test.exs`:

- **cancel-versus-child-completion across a parent restart** - the parent
  cancels, the process dies, and the child's answer arrives on a node that
  loads the parent from storage and has never seen the invocation live;
- **child-completes-while-parent-mid-restart** - the answer lands while
  the parent's position is being reloaded, so the liveness read and the
  step it gates must fall under one exclusion, not two.

Both are the same claim ADR-0007 made for a single invocation, made again
where the answering party is itself a durable run that can be mid-step.

**6. Nesting is allowed from day one, and its bound is the resolver's cycle
refusal.** A child may itself start a child. Nothing in this design limits
depth, and nothing needs to: a subchart that eventually resolves back to an
ancestor document is refused at resolve time with `cycle_refused`, which is
the protection statifier_blocks already ships and the only one this record
relies on. Whether the runtime additionally carries an ancestry list or a
depth ceiling is left open on purpose - it is a plan decision, ruled
neither way, and a guard added later changes no contract in this record.

**7. Fan-out is designed for and deliberately not built.** A subchart
inside a `foreach` means one invocation mapping to N children, and this
record names that seam without building it: the linkage of decision 2 is
per-child and does not assume one child per invocation, and aggregation - N
answers becoming one - would ride the same re-entry door as decision 3
rather than a new one. What is **not** decided is everything that makes
fan-out a feature: the aggregation vocabulary, what a partial failure means
to the parent, and what block shape expresses it at all (SCXML's `foreach`
is synchronous, so the natural expression is probably a new block type
rather than a reuse). Those get their own rulings walk, against working
single-child machinery. Nothing in decisions 1 through 6 may presume an
answer to them.

## Consequences

The reserved metadata namespace is a real cost and worth naming as one. A
host reading a child run's metadata now sees keys it did not write, and a
host that writes into the reserved prefix collides with the package. That
is the price of not putting a linkage column into every adapter's schema,
and it is bounded: the namespace is fixed, documented, and the only part of
`metadata` this package will ever read.

Cascade cancel is a multi-run operation with no global transaction. Each
child's cancel is its own serialized write under its own run's exclusion
(ADR-0004 decision 5), so a cancel of a deep tree is O(subtree) writes and
can be interrupted partway by a crash. It is written to be idempotent and
resumable rather than atomic - re-running a cancel over an already
cancelled subtree is a no-op - which is the same shape as every other
durable operation here and the only shape available without cross-run
locking, which this package does not have and does not want.

Retaining cancelled subtrees means storage grows with abandoned work.
Pruning is the host's policy and not this package's: nothing here deletes a
run, and a host with a retention rule applies it the same way it does to
completed runs.

The mandatory pin means a child cannot be resumed against a redeployed
chart. That is the intended behavior and the same trade ADR-0003 made for
every run - a refusal at load beats resuming a position into a document
whose states have moved - but it does mean a deploy that changes a child
chart strands in-flight children, and a host that cannot tolerate that
needs a chart-versioning story, not a looser guard.

ADR-0007's non-idempotency consequence reaches children unchanged: a parent
that stays in the invoking state after its child answers will accept a
redelivered completion, because the core removes an `active_invocations`
entry on exit and on nothing else. For a subchart this is less likely to
bite - the answering party is a run this package created and answers once -
but the door is the same door, and a host layering an at-least-once queue
in front of it owns the delivery-once discipline.

Finally, this record is half of a pair and does not stand alone. The
handler shape - what `statifier_blocks` offers a host in place of a pure
`start/2`, and how the refusal set is stated from there - is
`statifier_blocks` ADR-0008, *durable subchart invoke handler shape and
refusals*. The two were drafted together from one set of rulings and either
one read without the other will look like it is missing a side, because it
is.

## Amendment (2026-09-01, sp-2yx): decision 3's dispatch is handed the effect it is starting

Decision 3 says the `{:start_child, invoke, {:invoke, invoke}}` tuple is
"not renamed and not re-shaped", so that the in-memory and durable paths
plan the same instruction and a chart is portable between them. That
argument needs the durable dispatch fun to *have* the instruction's
payload, and until now it did not: `Driver`'s dispatch context was
`%{run_id, content_hash, invoke_id}`, so a handler had to build an
`%Invoke{}` out of an id plus a chart it already knew. A handler that
resolves its child by document id - `src`, per `sb-ADR-0008` decision 2 -
had nothing to resolve from.

ADR-0007 decision 5's amendment adds `invoke` to
`Driver.dispatch_context/0`, carrying the whole effect. Read that record
for the reasoning; recorded here because decision 3 is where the tuple's
"returns it unchanged from what it received" promise is made, and it was
not keepable before.

Nothing in this record's decisions changes. The linkage is still built from
the parent's run id, this invocation's id and index `0` (decision 7's
seam), the refusal set is still closed at four (decision 4), and the child
is still created inside the parent's serialization strategy and answered
through ADR-0007's public doors.

## Amendment (2026-09-01, sp-3n2): decision 2's linkage widens to an ordered set, and one child is the N=1 case

Decision 7 named the fan-out seam and refused to build it, and it was
explicit about what the linkage had to survive: "the linkage of decision 2
is per-child and does not assume one child per invocation". That walk has
now happened, in the three records that had to be walked together. This
amendment states the half of its outcome that is this package's, per the
operator's ruling.

Two accepted records depend on what follows and are cited rather than
restated:

- `statifier_blocks` **ADR-0009**, *durable fan-out is a new block type,
  `core.map`* (accepted 2026-09-01). Its decision 10 cites
  this amendment for the linkage widening, and it depends on exactly one
  thing from it: that the item index reaches the child's own metadata, so
  that its decision 5's index-ordered accumulation is recoverable when
  completions arrive out of order, after a restart, on a process that did
  not exist when the child started.
- `statifier_oban` **ADR-0007**, *fan-out child starts are batched*
  (accepted 2026-09-01). Its decision 5 derives a fan-out's
  resumable unit from the difference between the item indices and the
  indices already in this ordered set, holding no cursor of its own; its
  decision 4 makes the same index a component of the per-child job key.

**1. An invocation's linkage is an ordered set of child run ids with a
per-child status.** Decision 2 put the parent side in
`active_invocations`, whose entry for an invocation carried *the* child's
`run_id`. That entry is widened: it carries an ordered collection of
entries, one per child, each holding the child's `run_id` and that child's
status. Ordered means ordered **by item index**, which is the order the
entries are read back in and never the order they were written in; the
concrete encoding is the implementation plan's, not this record's.

The per-child status is here because the parent's own record is the only
place a reader can see the shape of a live fan-out without loading N child
runs. It is the same terminal vocabulary a run already has - ADR-0004
decision 2's arms plus this record's decision 5 cancelled arm - and it is a
denormalization of the child's own status, not a second authority over it:
the child run's record remains the truth, and a disagreement is resolved in
the child's favour.

**2. Child metadata gains the item index.** Decision 2 gave a child run's
metadata three values - the parent's `run_id`, the invocation id, and the
mandatory chart-identity pin. A fourth joins them: the child's **item
index**, its position in the list the fan-out ran over. It lives in the
same reserved, package-owned namespace decision 2 established, is read by
this package only, and is an identity in ADR-0006 decision 2's sense -
an integer position, never personal data.

The index is durably on the child rather than held by whatever started it,
and that is the whole reason it is worth an amendment. A completion
arriving through ADR-0007's doors can be placed at its index by a node that
has never seen the parent live, which is what makes `sb-ADR-0009` decision
5's ordering a function of the input rather than of the day it ran.

**3. One child is the N=1 degenerate case, not a separate shape.** The
single-child durable subchart of decisions 1 through 6 is an invocation
whose ordered set has one entry, whose child carries item index `0`. The
sp-2yx amendment above already describes it in exactly those words
("the parent's run id, this invocation's id and index `0`"), and this
amendment is what makes that phrasing load-bearing rather than
anticipatory. There is no single-child linkage shape and no multi-child
one; there is one shape, read at N=1 or at N=1000, and the step loop
(decision 1) still learns nothing about parents from either.

The cascade of decision 5 follows without special-casing: a cancelled
parent cancels every child in the set, recursively, retaining each record
under the distinct terminal status, and a late completion for any of them
is dropped by ADR-0007 decision 3's reverse look-up finding no live
invocation. `sb-ADR-0009` decision 6's `first_error` policy is that same
cascade addressed at siblings rather than at descendants, and it needs
nothing new here.

**4. Still no join table.** Decision 2 admitted one "only if the plan's
queries force it", and the queries this widening adds do not. *Find my
children* is the parent's own single-key read, now returning N ids instead
of one; *find my parent* and *find my index* are single-key reads of the
child's metadata, unchanged in kind. A `child_runs` table would buy
set-oriented queries - every live child across every fan-out - that no
accepted record asks for, and would cost every adapter a second required
schema, including adapters serving hosts that will never start a child.
The refusal stands where decision 2 left it, on the same condition.

**5. Multi-child linkage stays idempotent and resumable, not
transactional.** This amendment lands **no** atomicity guarantee over
creating N children, and the omission is deliberate rather than deferred.
This record's consequences already rule the shape for the multi-run
operation it built - cascade cancel is "idempotent and resumable rather
than atomic ... the only shape available without cross-run locking, which
this package does not have and does not want" - and creating children is
the same shape as cancelling them: N run records, each written under its
own run's exclusion (ADR-0004 decision 5), through an adapter behaviour
that cannot be assumed to share a transaction with anything.

So a fan-out is observably partial while it starts, and after a crash mid
start. What makes that harmless is the same thing that makes a partial
cascade harmless: the set is authoritative about which children exist, an
index missing from it has no child, and re-running the start creates only
what is absent. `sob-ADR-0007` decision 3 grounds its own non-atomic batch
on this record's ruling and names a transactional child-creation guarantee
here as its single reopen trigger. This amendment does not pull it, and a
later record that wants to must expect to reopen that one.

**Nothing here is implemented.** An operator ruling defers the
implementation; this amendment carries no `lib/` change and no test.
`active_invocations` still holds one child per invocation in the shipped
code, which is the N=1 case of what is described above and is why the
widening can land as a record without a migration.

## Note (2026-09-01, sp-21o): decision 5's cascade makes `list_runs_by_metadata/2` a capability requirement on a storage adapter

Recording clarification only. Nothing in the decisions above changes; this
states a consequence the record delegated and never spelled.

Decision 5 says a cancelled parent cancels "that child's own children,
recursively", and decision 2 refused a join table on the grounds that the
queries it foresaw - *find my child*, *find my parent* - are single-key
reads. The recursive walk is neither. It is a **reverse** query: given a
parent's `run_id` and an invocation id, enumerate the runs whose reserved
linkage metadata names them. `StatifierPersistence.Runs.cascade_cancel/3`
issues exactly that, once per node of the subtree, through
`StatifierPersistence.Storage.list_runs_by_metadata/2` over a match map
built by `StatifierPersistence.Run.Linkage.invocation_match/2` or
`parent_match/1`.

So the cascade forces a capability the storage-adapter behaviour (ADR-0003)
does not require of everyone, and the shape it took is the same one ADR-0006
decision 3 used for metadata itself: `list_runs_by_metadata/2` is an
**optional** callback, exporting it is how an adapter declares it can answer
"which runs name me as their parent", and an adapter that does not export it
is refused rather than degraded. `Storage.child_listing_supported?/1` is the
predicate; `StatifierPersistence.Driver`'s `start_child/3` consults it first
and returns `{:refused, :child_listing_unsupported}` **before any write**,
which is why decision 4's refusal set counts an unsupported adapter among its
four reasons. The `cancel_invoke` arm consults the same predicate and does
nothing for such a store, so a host that never starts a child pays not even
the cost of a query it could not satisfy.

The consequence is real rather than theoretical, and already documented
downstream. `statifier_examples`' SQLite-backed adapter omits the callback -
`list_runs_by_metadata/2` issues a `jsonb` containment query and SQLite
stores `metadata` as JSON text - so as of `statifier_persistence` 0.4.0 a
store on that adapter refuses a durable subchart before any write. Its
`StatifierExamples.Persistence` moduledoc says so in those terms and calls it
the contract working as designed. A host that wants durable subcharts over
SQLite wants an implementation of the callback in terms of the JSON-text
column, not a looser guard here.

The sp-3n2 amendment's decision 4 leaves this untouched: widening the
parent's linkage to an ordered set changes what *find my children* returns,
not whether an adapter must be able to answer the reverse query the recursive
walk depends on. The join-table refusal stands where decision 2 left it.

## Note (2026-09-01, sp-21o): decision 2's "`active_invocations` ... carries the child's `run_id`" is loose

Recording clarification only. The decision is unchanged; its phrasing names
the wrong container, and the sp-3n2 amendment above restated the phrase
rather than fixing it, so it is worth pinning down once.

`active_invocations` is core-owned. `Statifier.MachineState` types it as
`%{{state_index, invoke_index} => invoke_id}` - compiled-index pairs to
invocation id strings, hoisted off compiled data precisely so it holds no
host identity - and `Statifier.Position` carries it forward verbatim across a
persist and a resume. There is no room in it for a `run_id`, and this package
never writes into it. Read decision 2's phrase as naming the *relationship* -
the parent knows a live invocation, and that invocation has a child - not the
data structure that stores it.

The implementation honours the intent through the reserved, package-owned
metadata namespace decision 2 established. The linkage is recorded
**child-side**: a child run's `metadata` carries
`%{"statifier_persistence" => %{"parent_run_id" => ..., "invoke_id" => ...,
...}}` (plus the mandatory chart-identity pin, and the sp-3n2 item index).
*Find my parent* is the single-key read decision 2 promised, of the child's
own metadata; *find my children* is the reverse query the Note above
describes. Nothing about that weakens decision 2 - the parent's `run_id` and
the invocation id are still the linkage, still identities in ADR-0006
decision 2's sense - it only puts them where they actually live.

This is also why the sp-3n2 amendment could widen "the entry" to an ordered
set without a migration: there is no shipped `active_invocations` entry to
widen. The amendment's ordered set with per-child status is the logical
parent-side view of the linkage, whose "concrete encoding is the
implementation plan's, not this record's" - and today that view is derived
from the children rather than stored on the parent.

## Amendment (2026-09-06, sp-n8g): a run fails when its chart settles in a failure-classed final, tagged in that final's `<donedata>`

Decision 5's cascade and `sb-ADR-0009` decision 6's `first_error` policy
both key on a child run being `:failed`, and until now a chart had no way
to become one. `StatifierPersistence.Runs`' `run_status/2` reaches
`:failed` from budget exhaustion and from nothing else, and `Runs.fail/4`
is a host decision about a run rather than a chart transition (ADR-0004
decision 6). So a child whose chart handles its own error and settles
deliberately - the ordinary shape of *this one finished badly* - completes
as `:completed`, `first_error` never fires, and its siblings run on.
An earlier fan-out proof hit exactly that and worked around it
host-side, translating the condition through the public
`StatifierPersistence.Driver.answer_parent/3`.

This amendment closes that seam, per the operator's ruling of
2026-09-06. Its sibling is bead `sb-napt` in `statifier_blocks`, which
spends the tag named below in the block outcome vocabulary; ownership
splits the way decision 3 already splits it, stepping and run status here,
handler and block shape there. What follows is this package's half, and it
is deliberately the smaller half: one tag, one status arm, and no new
public function.

**1. The tag is a reserved `<donedata>` key,
`statifier_persistence:run_status`, whose value is `failed`.** A final
declares itself failure-classed by carrying one `<param>`, and needs
nothing else to say it - whatever other `<param>`s it carries for its
own reasons:

    <final id="ended_badly">
      <donedata>
        <param name="statifier_persistence:run_status" expr="'failed'"/>
      </donedata>
    </final>

The value set is **closed at `"failed"`**. Any other value - `"completed"`,
`"cancelled"`, an integer, an unresolved expression - is ignored, and the
run takes the status it would have taken without the key at all. A chart
may therefore ask for exactly one thing, which is the one thing decision 5
and `first_error` need to hear; a chart cannot claim `:completed` it did
not reach or a `:cancelled` that is the parent's word and not its own.
Widening the set is a later record's business and would reopen this one.

`<donedata>` is the carrier because it is the only place the durable
stepper can read a chart's own word without either a core change or a
layering violation, and two alternatives were considered and rejected on
exactly that ground:

- **A convention on the final's state id.** The `{:done, %Done{}}` effect
  carries `configuration`, and `MachineState` carries the compiled
  `machine`, so a state id *is* reachable here. But the ids a block
  compiler mints are its own grammar (`statifier_blocks` mints its
  root-termination finals under a `root_` role), and matching on them
  would make this package read a downstream compiler's naming scheme.
  A hand-written chart would have to adopt that scheme to say the same
  thing.
- **A compiled attribute on `<final>`.** SCXML declares no such
  attribute, so this would be a core change in `statifier`, which owns
  the interpreter contract and not this package. A seam this package can
  build inside its own contract does not get to reach upstream for one
  bit.

`<donedata>` costs neither. It is chart-visible, it is what a final is
already for, it needs no compiler and no core change, and it crosses the
invoke boundary unchanged - which matters, because the reader is often the
parent's settlement rather than the child's own host.

The key is namespaced the way decision 2 namespaces linkage metadata: a
reserved, package-owned prefix, read by this package only, with everything
outside it left exactly as opaque as it was. The separator is a **colon
rather than a dot** on purpose. A dotted key would be indistinguishable in
a predicator path expression from a nested map, so
`_event.data.statifier_persistence.run_status` would resolve a
`statifier_persistence` submap that is not there; a colon is not a
predicator identifier character, so the reserved key can be written by any
chart and pathed into by none. The name survives the whole pipeline as a
flat string key: on `statifier` 2.3.0, the floor this package depends on,
the final above resolves to `%{"statifier_persistence:run_status" =>
"failed"}` and compiles with no finding.

**2. The tag is read on the step that produced the `{:done, _}` effect,
and that step's run is `:failed`.** `run_status/2` gains a third
arm, ahead of its `machine_state.status == :done` arm and behind its
budget arm, so the order it decides in is: budget exhausted, then
failure-classed final, then done, then active. Both of the middle two
conditions hold on the same step - a failure-classed final *is* a top-level
final - and the tag is the tie-break.

Three things follow, and each is a deliberate narrowing rather than an
omission:

- The step is an ordinary successful step. It returns
  `{:ok, %StatifierPersistence.Run{status: :failed}, machine_state}`, not
  the `{:error, {:budget_exhausted, _}}` shape that route returns; a chart
  that says it failed has not malfunctioned, it has finished.
- The run's `donedata` carries the resolved `<donedata>` **verbatim, tag
  included**. Nothing is stripped. The tag's second reader is the block
  half's collect over a failed child, which needs to see it on the answer
  the parent is given, and this package does not edit chart-authored data
  on its way past (the same posture ADR-0006 decision 1 takes toward
  metadata).
- The run record's short `failure` string is `"failed_final"`, in the
  `<reason>` shape `failure_string/1` already writes for budget exhaustion,
  and it is the same string
  `[:statifier_persistence, :run, :terminated]` reports as `reason` and
  `maybe_answer_parent/3` sends the parent as `{:failed, reason: ...}`.
  Whether a detail is appended after a colon is the implementation plan's,
  as it is for the budget string.

**3. Settlement gains no rule.** This is the part worth stating plainly,
because it is what makes the amendment small. `Driver`'s `maybe_cancel/4`
already reads `Enum.any?(states, &(&1.status == :failed))` for a
`:first_error` linkage, and `terminal?/1` already counts `:failed` among
the three terminal statuses `settled?/3` waits for. So a chart-authored
failure cancels its live siblings through the cascade decision 5 built,
cancels its unstarted ones through the scheduler seam, and settles the
invocation - all by the path that already exists, reached by a status that
could not previously be produced. The seam was never a missing settlement
rule. It was a missing transition.

**4. Budget exhaustion stays a second route, and an unhandled `error.*`
is not a route at all.** Both halves are decided, and the second is the
one the operator ruled explicitly.

Budget exhaustion is untouched: it still yields `:failed`, still returns
`{:error, {:budget_exhausted, _}}`, and still writes its own `failure`
string. Two routes to one status is the intended shape - a run that
exhausted its macrostep budget and a run that reached a failure-classed
final are both failed, and a reader who needs to tell them apart reads the
`failure` string, which is what it is for.

An unhandled `error.communication` or `error.execution` that leaves a chart
with nowhere to go does **not** fail the run. Crash-as-failed was
considered and rejected: whether a chart that cannot continue has *failed*
is a judgement, and this record puts that judgement with the chart author,
who states it by transitioning to a failure-classed final, and with the
host, who states it through `Runs.fail/4`. It does not put it with the
stepper, which would have to infer intent from an event nobody handled.
The practical consequence is unchanged from today and is the honest one: a
chart that raises an error it does not catch stays `:active`, and that is a
chart bug the author fixes with a transition, not a status this package
invents on the author's behalf.

**5. A document compiled to terminate carries `<donedata>` on its
failure-classed finals.** Named here because the tag's carrier forces it,
and because the block half copies the spelling from this record rather
than re-deriving it.

`statifier_blocks`' compiler emits a top-level `<final>` per root outcome
under two options, and only one of them emits `<donedata>` today: a
`:child_use` final carries `<param name="outcome" expr="'<outcome>'"/>`,
and a `:terminate` final carries none, because nothing was listening. The
tag rides `<donedata>`, so a failure-classed outcome needs one under both.
That is a change to what a terminating document emits, and it belongs to
`sb-napt` along with every question this record does not answer: which
outcomes are failure-classed, how a block type declares that, and what
`core.map`'s collect does with a failed child. This record fixes the
spelling and nothing above it.

**6. The reference embedder's translation is deleted, not deprecated.**
`statifier_examples`' durable fan-out chart today inspects each chunk
child after its create-drive returns, finds it `:active`, and answers the
parent through `Driver.answer_parent/3` with
`{:failed, reason: "chunk_call_refused"}`. That code exists only because
this seam did not: with the chart routing its refusal to a failure-classed
final, the child reaches `:failed` on its own step and the driver's
automatic path answers the parent with no host in the loop. The host-side
translation goes away entirely rather than being kept as a supported
alternative - a second way to say a child failed is a second thing to keep
consistent with settlement, and `answer_parent/3` remains public for what
it is actually for, a host answering for a party that is not a run.

**Accepted 2026-09-06 (`sp-ive`), and implemented.** This
amendment carries no `lib/` change and no test, in the same posture the
sp-3n2 amendment above records for itself. `sp-hia` implements it - the
`run_status/2` arm, the `failure` string, and a case that drives a
failure-classed final through a `:first_error` fan-out - and this
section's acceptance is recorded separately once that lands.

**Note (2026-09-06, `sp-ive`):** that separate acceptance is this line, and
what it rests on is on `main` in both packages: `sp-hia` landed decisions 1
to 4 here (`run_status/2`'s third arm behind budget and ahead of `:done`,
the value set closed at `"failed"`, the `"failed_final"` string, donedata
passed on verbatim, settlement untouched), and `statifier_blocks`' `sb-napt`
landed decision 5, so a failure-classed outcome's final now carries the
reserved `<param>` under `:terminate` as well as `:child_use`. Decision 6 is
the one part still outstanding: `statifier_examples`' durable fan-out chart
still answers its parent with the host-side translation this record deletes,
and that deletion is a `statifier_examples` bead, not a reopening of this
amendment.

## Note (2026-09-06, sp-23z): what "the floor this package depends on" names in the sp-n8g amendment

Correcting a wording, not a decision. The sp-n8g amendment's decision 1
says the reserved key survives the whole pipeline as a flat string key
"on `statifier` 2.3.0, the floor this package depends on". Two different
versions are conflated in that clause.

`mix.exs`' `statifier_dep/0` declares `{:statifier, "~> 2.2 and >=
2.2.1"}`, so the floor this package depends on is **2.2.1**. **2.3.0** is
what `mix.lock` resolves that requirement to, and therefore the version
the amendment's claim was checked against.

Read the clause as *on `statifier` 2.3.0, the version this package's
`mix.lock` resolves to*. The claim it introduces - that the final resolves
to `%{"statifier_persistence:run_status" => "failed"}` and compiles with
no finding - is unchanged and still holds there. What the clause should
not be read as saying is that the declared floor guarantees it: a host
that pins `statifier` lower within the declared range checks that itself.

Nothing else in the amendment or in this record moves.

## Note (2026-09-06, sp-y7n): decision 3's answer reaches an outside fail too, through `Runs.fail/4`'s `driver:`

Decision 3 says a child answers its parent when it finishes, and every path
that does so hangs off a *drive of the child*: the automatic one runs after
`create/3`, `send_event/4` and `reenter/5` return, and the explicit one is
`Driver.answer_parent/3`, which a host calls when it has just driven the
child itself. `Runs.fail/4` is neither. It is ADR-0004 decision 6's
host-driven terminal transition - the host deciding *about* the run rather
than the chart deciding - so no interpreter runs, no drive returns, and
nothing looked at the child's linkage at all.

For an ordinary run that is exactly right. For a linked child it left the
parent's `<invoke>` `:pending` with nothing that would ever answer it, and
0.7.2's settlement made that permanent: an invocation now waits for every
child's recorded answer, and a child failed this way records none. This
note states the seam and what closes it, per the operator's
ruling. No decision above is edited.

**What was added.** `Runs.fail/4`'s `opts` gains `driver:`. Given one, a
run that carried linkage and actually reached `:failed` answers its parent
`{:failed, reason: reason}` - decision 3's spelling, the same payload the
automatic path builds from a run's stored `failure`. The alternative shape,
a `fail` door on `Driver` wrapping `Runs.fail/4`, was rejected for one
reason: it leaves the documented status-writing door still silently
orphaning parents, and a host that is already calling it would have no
signal to move. The option puts the fix where the defect is.

The answer itself is not new machinery. It goes through
`Driver.resolve_and_answer_parent/3`, the *only* new public function here
and one the mechanism forces: what the automatic path does is resolve the
parent's chart through `chart_resolver:` and then call
`Driver.answer_parent/3` with a driver over that chart, and a caller with
no drive to hang that off needs those two steps under one name. The
automatic path now calls it too, so there is one such site rather than two.
A driver with no `chart_resolver:` answers through `answer_parent/3`
directly, on its own `machine` - that function's existing contract, where
the host built the driver over the parent's chart. Nothing returns a wider
type than it did, and no callback was added to the storage-adapter
behaviour.

Because the answer goes through `answer_parent/3`, a fan-out child settles
rather than answering: the routing decision decision 3's amendment put in
that function serves both paths, and an outside fail on one child of N does
not complete the invocation.

**Where the exclusions sit.** The adapter behaviour has `lock_run/3` and no
general transaction callback, so "in the same transaction" is not something
this package can ask an adapter for. What it can do is take the two
exclusions in the order everything else here takes them: the child's status
write commits inside `Runs.fail/4`'s own serialization section, and the
parent's answer opens its own afterwards, sequentially. That is precisely
what `create/3` and `send_event/4` already do - they answer after their
drive returns - and it is why the answer is deliberately *outside* the
child's section: taking the parent's lock from inside the child's would
nest two run locks in an order nothing else in this package nests them in.
Decision 5 does not speak to lock order - it is explicit that a cascade is
idempotent and resumable rather than atomic, without cross-run locking - so
what the sequential shape keeps is not a rule stated there but the audited
one: every nested exclusion in this package is taken on a strict descendant
of the one already held (`sp-oq4`).

**The window this does not close.** Two writes in sequence have a gap
between them. A node that dies after the child's `:failed` commits and
before the parent is answered leaves exactly the state this note is about -
a settled child and a pending parent - and nothing in `Runs.fail/4`
retries. That is not a new window: it is the same one the stepped path has
carried since decision 3, because the automatic answer is a second write
after the child's own drive committed. Naming it is all this note does. The
thing that would close it is a recorded intent - the child's terminal write
persisting *that its parent is owed an answer*, and a sweeper resolving
what it finds - and that is a design with a cost (a second write on every
child's completion, or a scan) which no bead has yet paid for. A host that
needs the guarantee today gets it the same way it gets any at-least-once
guarantee: re-drive the fail. It is idempotent by construction - the second
call finds a terminal run and is `{:discarded, run}`, which answers nobody,
so a host whose crash happened *before* the answer re-drives it by calling
`Driver.answer_parent/3` (or `resolve_and_answer_parent/3`) on the child
directly, which a settled or cancelled invocation discards.

**What "on both backends" turned out to mean.** The conformance pair is
`DriverSubchartEctoTest` on real Postgres and `Ecto.SqliteMigrationsTest`
on SQLite, not a case in
`StatifierPersistence.Testing.StorageConformance`: that suite generates
adapter-level cases that go through `Storage` and the adapter callbacks,
and this behaviour is the driver's, over a chart. The two halves assert
different things, and the difference is a finding worth recording.
Linkage is run `metadata` (decision 2), `Storage.Ecto` declares metadata
support on Postgres only, and `insert_run/5` refuses metadata an adapter
does not support - so **a durable subchart child cannot be stored on SQLite
at all**. It is the same root cause that stops a fan-out at open, the
metadata conjunct inside `Storage.child_listing_supported?/1`, reached by
two doors and answered with two different refusals:
`{:error, :metadata_unsupported}` from the child's own insert, and
`{:refused, :child_listing_unsupported}` from `start_child_at/6`.
The SQLite case
therefore asserts what `driver:` has to be there: inert. An outside fail
reads `:no_parent`, answers nobody, and behaves exactly as it did before
the option existed. Whether decision 2's linkage should have a non-metadata
home for such a backend is a question this note opens and does not answer.

**Accepted 2026-09-06 (`sp-y7n`), and implemented.** In the
posture the sp-n8g amendment above records, inverted: that section carried
no `lib/` change and waited for one, and this one ships with its own. The
`driver:` option, `resolve_and_answer_parent/3` and both halves of the
conformance pair land in the same pull request as this section, so there is
no window in which the note describes something that is not on `main` - and
that is what lets the acceptance be recorded here rather than separately.

## Amendment (2026-09-08, sp-sli): `Driver.new/3` takes an `after_step:` callback, fired after every step the driver drives on a caller's behalf

**Status: accepted (2026-09-08, `sp-nhl`; drafted the same day as `sp-sli`
under the operator's ruling, flipped once
`sp-c48` landed - the Note at the foot of this file names the merge and
what was re-read against it).** Additive; decisions 1 to 7 stand
exactly as accepted, and every amendment and note above is unchanged - the
sp-y7n note directly above this one names the path this section is mostly
about. `sp-c48` implements it and `sp-nhl` flips this status line once that
has landed, in the same posture the sp-n8g amendment above records for
itself: this section carries no `lib/` change and no test, and waits for
one. Every code cite below names its anchor and was read at `4e3e2c8`.

**The seam this opens, and who asked for it.** The first production
embedder keeps an append-only record of run events, which it folds to
reproduce a position without reading the run's checkpoint. Every delivery
it makes itself it can append, because it is the caller. The trouble is the
deliveries it does not make: decision 3's answer steps the *parent* from
inside the child's drive, with no host call in the loop, and the sp-y7n
note's `driver:` option steps the parent from inside a `Runs.fail/4` call
that is about a different run entirely. Those steps happen, they persist,
and the host has nothing to append for them - so its fold and the stored
checkpoint disagree for exactly those deliveries, which are the ones a
subchart's lifecycle is made of.

Two ways out were available. The host could stop using the package's answer
path and re-implement it - read the linkage, resolve the parent, deliver
the answer itself - which is the shape the sp-n8g amendment above records
the earlier fan-out proof taking, translating its condition through the
public `StatifierPersistence.Driver.answer_parent/3`, and which the sp-y7n
note above names as the explicit host door beside the automatic one. The
embedder has instead ruled to keep the package route and asked for the
seam, and this amendment is that seam: a callback the driver fires after
each step it takes on a caller's behalf, so a host can append what the
package stepped.

Nothing in this package answers that today. `dispatch` and the `effects:`
executor (`Driver.new/3`'s options, read at `4e3e2c8`) are per-*effect*
doors called from inside a step, not after one; the drive's own return
value reports one step, the last (the `t:StatifierPersistence.Driver.result/0`
typedoc, read at `4e3e2c8`), and reports nothing at all about a parent
stepped on the answer path, whose result `maybe_answer_parent/3` discards.
ADR-0009's telemetry sees every step and is deliberately the wrong tool -
decision 5 below says why.

**1. `Driver.new/3` takes `after_step:`, a 3-arity function, stored on the
struct, `nil` by default.** It is called
`after_step.(run_id, machine_state, effects)`: the id of the run that was
stepped, the `t:Statifier.MachineState.t/0` that step's result carries, and
the effects that step produced. It joins the driver's existing optional
options on the struct (`defstruct` at `driver.ex`'s `@enforce_keys
[:store, :machine, :dispatch]`, read at `4e3e2c8`, where `effects`,
`invoke_types`, `serialization`, `chart_resolver` and `child_canceller` all
already sit as `nil`-defaulting fields beside `max_turns: 1_000`) and is
read in `new/3` with the same `Keyword.get/2` shape as its neighbours
(`def new(%Storage{} = store, %Machine{} = machine, opts)`, read at
`4e3e2c8`). `nil` means "this driver reports no steps", which is what every
driver built before this option existed keeps meaning.

Which effects, precisely: the whole effect list of that step - the list
`Runs`' persist tail is handed and reports, before it splits the lifecycle
effects off from the executable ones (`defp persist_tail(store, run_id,
machine_state, effects, executor, write)` in `runs.ex`, whose first act on
that list is `Enum.split_with(effects, &lifecycle_effect?/1)`, read at
`4e3e2c8`). Not the executable subset that reaches the driver's own
executor (`defp executor(driver, ref)` in `driver.ex`, read at `4e3e2c8`),
which by construction never sees a lifecycle effect: a host folding events
back into a position needs what the step produced, not what happened to be
executable. This record does not choose the seam that carries that list out
of a `Runs` entry point and into the driver - that is `sp-c48`'s, and it is
the one part of this amendment with real implementation cost. What the
record does rule out is widening the return of a public `StatifierPersistence.Runs`
function to carry it, which would move every caller of a documented door
for the benefit of one optional callback. If no seam is reachable under
that constraint, the answer is a question back to this section, not a
quietly narrowed third argument.

**2. It fires after every `Runs` entry point this driver calls on a
caller's behalf.** There are two such entry points, and both are named
here rather than left to "every step" to read: `Runs.create/4`, called once
by `create/3`, and `Runs.step/5`, called by the private `step/5`
(`defp step(driver, run_id, opts, event, ref)`, read at `4e3e2c8`) - which
is where `create/3`'s and `send_event/4`'s answer loop (`advance/6`) and
both late-answer doors (`done_invocation/5` and `failed_invocation/5`,
through `defp reenter(driver, run_id, opts, invoke_id, answer)`, read at
`4e3e2c8`) all arrive. A drive that takes three turns fires the callback
three times. `Runs.cascade_cancel/3`, the third `Runs` function this module
calls (from `maybe_cancel/4` and from `perform/5`'s `:cancel_invoke` arm,
read at `4e3e2c8`), steps nothing and fires nothing.

The parent's step on the answer path is covered by that sentence and not by
an exception to it, because the answer path arrives at the same private
`step/5` through the same doors: `answer_parent/3` routes a single-child
answer through `respond_to_parent/3`, which calls `done_invocation/5` or
`failed_invocation/5` on a driver over the *parent's* chart. So the
callback fires with **the run id of the run that was stepped** - the
parent's, there - which is the only spelling under which a host can append
the row to the right run's log. `Runs.fail/4`'s `driver:` path reaches the
same place: `defp answer_parent_of_failed({:ok, %Run{status: :failed}} =
result, run_id, reason, opts)` in `runs.ex` (read at `4e3e2c8`) calls
`Driver.resolve_and_answer_parent/3`, which resolves the parent's chart and
answers through `answer_parent/3`.

Nothing has to be plumbed for the nested cases, and that is a property of
how this module already builds its inner drivers rather than a new promise.
A child is driven by `%{driver | machine: child_machine}` (`defp
create_child(driver, resolved, context, child_machine, content_hash,
fan_out)`, read at `4e3e2c8`) and a parent is answered by
`%{driver | machine: parent_machine}` (`defp resolve_and_answer(driver,
%Linkage{} = linkage, run_id, payload)`, read at `4e3e2c8`); in both, every
field but `machine` travels. An `after_step:` therefore reaches a child's
own steps, a grandchild's, and a grandparent's answer, with the stepped
run's id each time - which is exactly the set of steps the host cannot
otherwise see.

**3. It fires after that step's persist, in the order the steps happened,
and outside the exclusion of the run it reports.** After the persist,
because a host appending a row for a step that then failed to write would
be recording a position that does not exist; the callback is reached from
the driver, once the `Runs` entry point has returned, not from inside
`persist_tail/6`. In order, because the driver's own loop is sequential -
`advance/6` recurses one answer at a time - so "the order the steps
happened" needs nothing to enforce it. And outside the stepped run's own
exclusion, because `serialized/5` closes before that entry point returns
(`def fail(%Storage{} = store, run_id, reason, opts \\ [])`, read at
`4e3e2c8`, is the clearest instance of the shape: it answers the parent
after its own serialized section, deliberately, for the reason the sp-y7n
note above gives).

What that guarantee is scoped to is the run being reported, and the scope
is worth stating because one path makes the difference visible. Decision
3's single child is created from *inside* the parent's step, through the
executor, inside the parent's serialization section. The child's create is
a full drive, so the callback fires for the child's own steps - correctly,
with the child's run id - while the parent's exclusion is still held. This
section does not change that ordering, and a host must not read clause 3 as
a promise that no run lock is held anywhere when its callback runs. What it
promises is narrower and is the part a host can act on: the callback for a
given run never runs inside that run's own exclusion, so a callback that
reads or writes the run it was handed cannot deadlock against the step that
produced it.

**4. Its return value is ignored, and a raise inside it propagates to the
caller.** Ignored, because clause 5 makes the callback an observer and a
returned value would be the first step toward it not being one. Propagating,
because the callback exists to keep a host's own record in step with this
package's, and a host whose append failed has exactly the divergence the
callback was added to prevent - swallowing that would hide it at the one
moment it is cheap to see. A host that must not fail the drive for it wraps
its own body in whatever it wants the failure to mean; a host that must not
*continue* the drive gets that for free. The cost is stated plainly: an
`after_step:` that raises can leave a drive part-taken, with the steps
before it persisted, and the recovery is the same at-least-once re-drive
every other window in this record has.

**5. What it is not.** It is not a telemetry event, and ADR-0009 stays the
observability seam untouched: telemetry there is a point-in-time report to
detachable handlers, whose failure is nobody's business but the handler's,
and this is a decision-carrying, ordered, synchronous callback whose failure
is the caller's (clause 4). Recording the same steps twice on two seams with
opposite failure semantics is deliberate, not redundant. And it is not a way
to alter the step: the machine state and the effects are handed over for
reading, the return is discarded, and a driver with an `after_step:` and one
without take the same steps and persist the same positions.

**Worked example.** A durable subchart's child run whose host decides,
outside the chart, that it has failed. The host calls
`StatifierPersistence.Runs.fail/4` on the child with `driver:` set (the
sp-y7n note's option), on a driver carrying both a `chart_resolver:` and an
`after_step:`. The child's status write commits inside its own serialized
section. The answer then opens outside it, resolves the parent's chart, and
delivers `{:failed, reason: reason}` to the parent's `<invoke>` - which
steps the parent, possibly several times as its own answer loop runs. The
host's record gains one row per parent step, each carrying the parent's run
id, and its fold now reproduces the parent's checkpoint. Before this
option, that call appended nothing at all: the only run the host named was
the child, and the child was never stepped.

**What this section does not decide.** Whether the callback should also see
a run whose step was *discarded* (`{:discarded, run}`, where no step
happened and nothing persisted) - clause 2's "every `Runs` entry point"
means every call that stepped, and a discarded delivery is not one. Whether
a host can ask for the callback per call, as `create/3` and `send_event/4`
already allow for `invoke_types:` and `serialization:`; the option is
declared on the driver here and `sp-c48` may add the per-call override if
the same `Keyword.put_new/3` shape carries it, which is a widening of this
clause rather than a departure from it. And nothing about ADR-0010's input
log, which records what was *delivered to* a run rather than what the
package stepped; the two answer different questions and neither is built
out of the other.

## Note (2026-09-08, sp-nhl): the `after_step:` amendment above is accepted - what landed, and the five things checked before the flip

`sp-c48` has landed - `e3209bd` on `main`, PR 91 - and the amendment above
is accepted as of that merge. Every clause of it, its worked example and
its closing "what this section does not decide" were re-read against `main`
at `3fd45f7` (`e3209bd` plus the 0.11.0 prep, which touches none of this)
before the flip, and each holds as written. Five things are worth recording
where the flip is recorded, none of them a change to what was decided.

**The seam clause 1 left open is a package-internal `step_reporter:`.**
Clause 1 named the list and refused to widen a public
`StatifierPersistence.Runs` return to carry it, and left the seam itself to
this bead. What landed is an option, not a return: `step_reporter:` joins
`StatifierPersistence.Runs`' `t:opt/0` union, documented there as "this
package's own, never a host's", set by `StatifierPersistence.Driver` only
when its own `after_step:` is set, and threaded to the persist tail
(`defp persist_tail(store, run_id, machine_state, effects, executor, write,
reporter)` in `runs.ex`, read at `e3209bd`). No public return widened, which
is the constraint clause 1 actually placed. Note the cite in clause 1 itself
is that same function at its old arity six; it gained the reporter argument
and nothing else moved.

**Clause 1's "whole list" and clause 2's "two entry points" both hold, and
are the two claims a reader should check first.** The tail reports the list
it was handed, not the executable subset: `report_step/3` is reached from
`persist_tail/7` with that function's own `effects` parameter, which
`Enum.split_with/2` never rebinds (`runs.ex` at `e3209bd`), and
`DriverTest`'s "hands over the whole effect list, lifecycle effects
included" asserts a `{:done, _}` reaches the callback and does not reach the
executor. And the driver still calls exactly three `StatifierPersistence.Runs`
functions - `Runs.create/4` from `create/3`, `Runs.step/5` from the private
`defp step(driver, run_id, opts, event, ref)`, and `Runs.cascade_cancel/3`,
which steps nothing - so the two step-taking entry points clause 2 names are
still the whole set. The driver drains the reporter's messages and fires the
host's callback from those two sites, after the entry point has returned.

**The per-call override landed as `Keyword.get/3` against the driver's own
default, not `Keyword.put_new/3`.** The closing section allowed the widening
"if the same `Keyword.put_new/3` shape carries it"; what `driver.ex` holds
at `e3209bd` is `defp after_step(driver, opts), do: Keyword.get(opts,
:after_step, driver.after_step)`. The two spell the same rule - the caller's
option outranks the driver's field - from opposite ends, and the second is
what the option's own shape asks for, since the value being defaulted lives
on the struct rather than in the keyword list. The widening is the one the
section allowed; only the spelling differs, and it is named here rather than
edited into the clause.

**The discarded delivery is answered the way the closing section said, and a
test holds it.** "A discarded delivery is not one" is now two independent
refusals: nothing persisted means the reporter is never called, and
`Driver`'s own `report/4` matches only `{:ok, _run, _machine_state}` on its
side of the seam. `DriverTest`'s "a discarded delivery fires nothing" records
a sabotage that needed both halves broken to go red.

**Clause 3's lock statement holds by construction and no test asserts it.**
"The callback for a given run never runs inside that run's own exclusion" is
true because `serialized/5` closes before the `Runs` entry point returns and
the callback fires after that return - it is a property of where the call
sits, and there is no test that would go red if it moved. That is recorded
here rather than papered over: the claim holds as written at `e3209bd`, and
a future edit that fires the callback from inside `persist_tail/7` would
falsify it silently.

**Two sentences above that the flip and a reviewer touch.** The amendment's
own status paragraph says "this section carries no `lib/` change and no
test, and waits for one"; that is now false, and it is met here rather than
edited in place - the code and its tests are `e3209bd`. And the closing
sentence of the seam section reads "ADR-0009's telemetry sees every step and
is deliberately the wrong tool - decision 5 below says why". Read "decision
5" there as **clause 5**, the amendment's own fifth clause ("What it is
not"), which is what the sentence points at; this record's decision 5 is the
cascade, and the section's other self-references say "clause N".

## Note (2026-09-12, sp-pcw): `run` in this record is the noun now called `execution`, and the clause 3 wording a review queued is already the amendment's text

Two items, both met by addition: nothing above is edited, and this record is
read at the dates its sections were decided.

**1. Read `run` as `execution` from 0.12.0.** Every `run` in this file - the
durable noun, the module and function names, the ids and the column names it
cites - names the record this package now calls an `execution`. The rename
landed on `main` at `5f8ca12` (sp-op4) with its pin tightened
at `05993b0`. `StatifierPersistence.Execution` and
`StatifierPersistence.Executions` are the modules
(`lib/statifier_persistence/execution.ex:1`,
`lib/statifier_persistence/executions.ex:1`), the error atom is
`:execution_not_found` (`lib/statifier_persistence/executions.ex:710`), and the
telemetry family is `[:statifier_persistence, :execution, ...]` carrying
`execution_id` metadata (`lib/statifier_persistence/telemetry.ex:60-62`) - each
read at `05993b0`. The table, column and index half (sp-j2y's V06) follows in
the same release, and the whole rename ships in 0.12.0.
**ADR-0011 governs the noun** (`docs/adr/0011-execution-is-the-durable-noun.md`,
proposed at `05993b0`; it flips once the code and the migration are on `main`).
This record's decisions are unchanged by the rename - only the word is - and
the file name keeps `child-runs` because a file name is a cite target.

**2. Clause 3 of the `after_step:` amendment already carries the narrow
promise the review queued, scoped to the run it reports.** The review
queued an item on the reading that clause 3 promises the callback fires
outside *any* run lock, asking for the narrower wording on the grounds that
decision 3's child is created inside its parent's serialization section, so
the child's callback fires while the parent's exclusion is still held. That is
a correct reading of the mechanism and it is already the record's text - so
the queued item is answered here rather than corrected above. Clause 3's own
sentence is scoped to one run: "It fires after that step's persist, in the
order the steps happened, and outside the exclusion of the run it reports"
(:871-872, read at `05993b0`). The paragraph beneath it states both halves of
the queued concern explicitly - the child case ("the callback fires for the
child's own steps - correctly, with the child's run id - while the parent's
exclusion is still held", :889-890) and the refusal of the broad reading with
the narrow promise in its place ("a host must not read clause 3 as a promise
that no run lock is held anywhere when its callback runs. What it promises is
narrower and is the part a host can act on: the callback for a given run never
runs inside that run's own exclusion", :891-894). The sp-nhl Note above
restates that same sentence where it records that the claim holds by
construction and that no test asserts it (:1001-1003).

Nothing in clause 3 changes, then, and no wording is replaced. What is worth
carrying forward is the reading, which item 1's noun sharpens: the guarantee is
per-execution, not per-process. A callback handed execution E never runs inside
E's own exclusion, and may run inside E's parent's.

## Note (2026-09-13, sp-478): the donedata key is the one `run` the Note above does not sweep in

Pure addition, one clause on the 2026-09-12 Note's item 1. That item reads
every `run` in this file as an `execution` from 0.12.0. The reserved donedata
key is the exception: `statifier_persistence:run_status` keeps its spelling as
a key that is still *read* for one release. 0.12.0 reads both it and
`statifier_persistence:execution_status` - the new key wins where both are
present, and the old one logs one deprecation line - and 0.13.0 reads only the
new one (ADR-0011 decision 4; `@execution_status_key`
`lib/statifier_persistence/executions.ex:1686` and
`@legacy_execution_status_key` `:1694`, read at `71537dc`). The failure-classed
final this record's amendment decides is otherwise unchanged: same mechanism,
same closed value set, only the key name moves.

## Note (2026-09-13, sp-bij): the 2026-09-12 Note's closing gloss, said without the word "process"

Pure addition, one sentence on the 2026-09-12 Note's item 2; that item's
own words are left as written.

Item 2 closes "the guarantee is per-execution, not per-process"
(read at `8211e03`). The second half of that contrast is not the record's.
Clause 3 of the `after_step:` amendment, the paragraph beneath it, and the
sp-nhl Note all draw the contrast between the exclusion of the execution
the callback reports and *any* execution lock held anywhere - "a host must
not read clause 3 as a promise that no run lock is held anywhere when its
callback runs", the sentence item 2 itself quotes. Processes appear in
none of them.

Read the closing gloss, then, as: the guarantee is per-execution - **not a
promise about every lock**. The sentence item 2 ends on is the accurate
form and is unchanged: a callback handed execution E never runs inside E's
own exclusion, and may run inside E's parent's.

## Amendment (2026-09-23, sp-3l2a): a child's linkage pin follows a migration of that child, and nothing else rewrites it

Status of this amendment: accepted (2026-09-23, sp-3l2a). The record above
stays accepted; this amendment is proposed until the operator accepts it.

Decision 2 makes the linkage's chart-identity pin mandatory: the same
content hash `Statifier.Machine.identity/1` produces for the child's own
chart, recorded a second time where the parent-child relationship can see
it. Execution metadata is write-once (ADR-0006 decision 1), so until now
nothing could change the pin, and nothing needed to: a child's chart never
changed. ADR-0013 changed that for one execution and left children
untouched (its decision 7, `docs/adr/0013-the-migration-plan.md`);
ADR-0014 gave a refused migration a status to wait in
(`docs/adr/0014-the-needs-migration-status.md`); ADR-0015 moves a tree of
executions, a child among them, onto new charts
(`docs/adr/0015-the-tree-migration.md`).

**It amends decision 2.** The pin pins the child's own chart, so it
follows a migration **of that child** and nothing else:

- When `Executions.migrate_tree/4` re-pins a child, in the one store unit
  ADR-0015 decision 3 decides, the same write rewrites the linkage's
  `content_hash` to the content hash of the chart the child now walks.
  This is the one sanctioned rewrite of the linkage. Every other value
  under the reserved key - `parent_execution_id`, `invoke_id`,
  `child_index`, and a fan-out's `child_count` and `policy` - is written
  once at create and never again.
- A parent's migration rewrites nothing in any child, by `migrate/4` or by
  the tree command: a child absent from the plans keeps its row, its
  position and its pin (ADR-0013 decision 7).
- The write-once rule stands for every other metadata key, the host's
  keys included.

The pin keeps the meaning decision 2 gave it. After the rewrite it is
again the identity hash of the chart the child's own row is pinned to,
which is what decision 2 says it records, and ADR-0012's retirement counts
the child's pin against its new chart rather than the one it left.

## Note (2026-09-23, sp-o2ev): the sp-3l2a Amendment is accepted

The operator accepted the 2026-09-23 sp-3l2a Amendment on 2026-09-23,
after the code that implements it shipped in statifier_persistence 0.15.0
(tag `v0.15.0`, `ae9c855`). That Amendment's own status line flips in
place from proposed to accepted, and the record above stays accepted. Its
"this amendment is proposed until the operator accepts it" is met here
and stays as written. Every cite below was read on `main` at `ae9c855`.

What was re-read before the flip:

- **One key is rewritten.** A re-pin rewrites only `content_hash` under
  `Linkage.reserved_key/0` and carries every other metadata key forward
  (`lib/statifier_persistence/storage/ecto.ex`, `linkage_update/3`;
  `lib/statifier_persistence/storage/in_memory.ex`, `repin_linkage/2`).
  `parent_execution_id`, `invoke_id`, `child_index`, `child_count` and
  `policy` are written at create only
  (`lib/statifier_persistence/execution/linkage.ex`, the struct).
- **Only the tree command rewrites it.** In `lib/`,
  `Storage.write_tree_migration/2` is called only by
  `Executions.migrate_tree/4`, which writes a pin for a named node that
  carries a linkage (`lib/statifier_persistence/executions.ex`,
  `linkage_pin/3`). A child absent from `plans` is neither locked nor
  written.
- **`migrate/4` rewrites no pin.** It writes through
  `Storage.update_execution/5`, which carries the stored metadata forward
  (`executions.ex`, `repin/5`).

## Amendment (2026-09-24, sp-51ah): a single child's answer is recorded on its own record, and a refused one is delivered again from it

Status of this amendment: accepted (2026-09-25, sp-51ah). The record above
stays accepted; this amendment is proposed until the operator accepts it.

Decision 3 has a child answer its parent through ADR-0007's doors. A
fan-out child's answer is also kept: a settlement records it on the child's
own execution record (`lib/statifier_persistence/driver.ex`,
`record_outcome/3`, read at `d72c92e`) and assembles the parent's answer
from those records (`entry/5`, read at `d72c92e`), so answering again
through any one child settles the invocation again from storage. A single
child's answer was kept nowhere. `Driver.answer_parent/3` took it to the
parent's door and wrote nothing (`answer_parent/3`, read at `d72c92e`), and
`StatifierPersistence.Execution.from_record/1` said a stored record carries
no donedata (`lib/statifier_persistence/execution.ex`, `from_record/1`,
read at `d72c92e`). A parked parent refuses an answer whole (ADR-0014
decision 2), and ADR-0015 leaves what the answering side does with that
refusal undecided (its "What this record does not decide"). So a refused
single-child answer could be delivered again only from the value the host
held where it drove the child, which is what ADR-0009's sp-6neq Amendment
says in its decision 3. Ruled by the operator, 2026-09-24: a refused
single-child answer is answered again from the child's own stored terminal
record, through the entry point a fan-out answers again by; the settlement
event keeps reporting the settlement's decision; nothing is added to any
vocabulary.

**1. A single child's answer is recorded on its own execution record.** It
is kept in the column a fan-out child's answer is kept in, the V03
`outcome_blob`, with the encoding `record_outcome/3` uses. It is recorded
before the parent's door is tried, in `answer_parent/3`'s single-child
branch, and when `Driver.resolve_and_answer_parent/3`, the path the
automatic answer takes, never reaches the parent: the `:parent_unfetched`
and `:parent_chart_unresolved` cases (`record_single_answer/3` and
`unreached/5`, in this change). Those are the answers a host may have to
deliver again. It is recorded once: only
when the child's stored status is the terminal status the answer names
(`:completed` for `{:done, _}`, `:failed` for `{:failed, _}`), only when
the record holds no answer yet, and only on an adapter that declares it can
store one (`StatifierPersistence.Storage.execution_outcome_supported?/1`).
Unlike `record_outcome/3` it derives no status: it writes the stored status
and `failure` back as they are. A write that fails does not stop the
answer, which goes to the parent's door either way. No column, schema
version or adapter callback is added.

**2. The recorded answer reads back through the host-facing struct.**
`Execution.from_record/1` builds `donedata` from a recorded
`{:done, donedata}` answer, and leaves it `nil` for a recorded failure and
for a record with no answer (`donedata/1` in `execution.ex`, in this
change). This holds for a single child and for a fan-out child alike. A
failed child's reason was on its record before this change, as `failure`.
A host delivering an answer again fetches the child's record and calls
`Driver.answer_parent/3`, the entry point a fan-out answers again by, with
`{:done, execution.donedata}` or `{:failed, reason: execution.failure}`.
This is the one documented behaviour that changes: `from_record/1` no
longer answers `donedata: nil` for every record. Nothing is queued inside
this package; ADR-0014 decision 8 and the sp-6neq Amendment's decision 4
hold, and the delivery again is still the host's.

**3. A child that ended before this change holds no recorded answer.** Its
record builds `donedata: nil` as it did before, and nothing fills the
answer in later. Its fetched record's `outcome_blob` is `nil`, and that is
how a host tells it apart from a child whose donedata is itself `nil`. A
completed child of that kind is answered again only from what the host
held. A failed one is still answered from its `failure`.

**4. `[:statifier_persistence, :child, :settled]` does not name a refused
answer.** Its `decision` stays the settlement's own
(`decision_atom/1`, called from `report_settled/3`, read at `d72c92e`):
`:answer` means every index is settled and the assembled list goes to the
parent's door. A parked parent that then refuses the list still reports
`:answer` there. What the door answered is the `delivery` on the
`:answered` event that follows. `docs/telemetry.md` and the
`StatifierPersistence.Telemetry` moduledoc now say so. No event, key or
value is added, so ADR-0009 decision 8's count of event names does not
change, and `:recorded` stays the fan-out settlement's event: a single
child's recorded answer emits nothing of its own.

The sp-6neq Amendment's decision 3 still holds for an answer the host kept.
It is no longer the only way to deliver a single child's answer again. This
amendment edits nothing in ADR-0009.

No other decision moves.

## Note (2026-09-25): the sp-51ah Amendment is accepted

The operator accepted the 2026-09-24 sp-51ah Amendment on 2026-09-25. The
code that implements it landed in PR 173 (`c4ff5b4`) and shipped in
statifier_persistence 0.18.0 (tag `v0.18.0`, `453f630`). That Amendment's
own status line flips in place from proposed to accepted, and the record
above stays accepted. Its "this amendment is proposed until the operator
accepts it" is met here and stays as written. Every cite below was read on
`main` at `adca4f0`, which carries 0.19.0 and no change to them.

What was re-read before the flip:

- **Decision 1.** `answer_parent/3`'s single-child branch and the
  automatic answer's unreached path record the answer through
  `record_single_answer/3` and `unreached/5`
  (`lib/statifier_persistence/driver.ex`), and the record is written only
  on an adapter for which
  `StatifierPersistence.Storage.execution_outcome_supported?/1` answers
  true.
- **Decision 2.** `Execution.from_record/1` builds `donedata` from the
  recorded `outcome_blob` through `donedata/1`
  (`lib/statifier_persistence/execution.ex`).
- **Decisions 3 and 4.** A record with no `outcome_blob` reads
  `donedata: nil`, and the settlement event's vocabulary is unchanged; the
  0.18.0 section of `CHANGELOG.md` names the recorded answer and adds no
  event.
- **The tests.**
  `test/statifier_persistence/driver_single_child_answer_test.exs` carries
  the recorded answer and its delivery again.

## Amendment (2026-11-19, sp-lp5): a durable child's linkage can have a home outside `metadata` on a backend that cannot store `metadata`, for a host that opts in, and a host can read an execution's active children

Status of this amendment: accepted (2026-11-19, sp-lp5). The record above
stays accepted; this amendment is proposed until the code that implements
it ships in a published version and every claim below verifies against
`main` at that version. Every cite below was read on `main` at `ce3cd44`.

Decision 2 puts a child's linkage in the execution's `metadata`, under the
reserved key `StatifierPersistence.Execution.Linkage.reserved_key/0`
(`lib/statifier_persistence/execution/linkage.ex`). That made a durable
child storable only where `metadata` is. The shipped Ecto adapter declares
`metadata` on Postgres only (`supports_metadata?/1` in
`lib/statifier_persistence/storage/ecto.ex`), because its two listings are
`jsonb` containment SQL. So on any other Ecto backend a child is refused
twice over. `Storage.insert_execution/5` refuses the child's own insert
with `{:error, :metadata_unsupported}` (`check_metadata_supported/2` in
`lib/statifier_persistence/storage.ex`). Before that, the starts refuse at
open: `Storage.child_listing_supported?/1` and
`Storage.execution_states_supported?/1` each require
`metadata_supported?/1`. A single child's start refuses
`:child_listing_unsupported` (`start_child/3` in
`lib/statifier_persistence/driver.ex`), and a fan-out's
`Driver.start_child_at/6` checks both predicates (`settleable/4`, same
file).

The sp-y7n Note of 2026-09-06 ends on the question this amendment
answers: "Whether decision 2's linkage should have a non-metadata home for
such a backend is a question this note opens and does not answer." The
operator ruled the answer on 2026-11-19. It is not a documented refusal.
`statifier_persistence` builds the home, and the build ships in a minor
release. Ruled by the operator, 2026-11-19. What follows is the shape. Its
engineering choices were decided by the conductor under a standing
consent, 2026-11-19.

**1. At the adapter seam the linkage keeps travelling under the reserved
key.** The facade hands an adapter the child's linkage inside the record's
`metadata`, under `Linkage.reserved_key/0`, as it does today, and an
adapter hands it back the same way. A linkage match is still a `metadata`
match map (`Linkage.parent_match/1`, `Linkage.invocation_match/2`).
`Linkage.from_metadata/1` stays the one reader of a stored linkage in
`lib/`. No callback changes shape, no record field is added, and no reader
in `Driver` or `Executions` moves. So an adapter a host wrote against
0.25.1 sees the same records and the same matches on 0.26.0, and answers
them the same way. Decision 2's refusal of a first-class linkage column
in every adapter's required schema stands: what follows is one adapter's
storage choice and one optional declaration, never a schema the behaviour
requires.

**2. A store can declare linkage without declaring `metadata`.** The
adapter behaviour gains one optional callback, `supports_linkage?/1`, and
the facade one predicate, `Storage.linkage_supported?/1`, with the shape
`metadata_supported?/1` already has: the adapter exports the callback and
it answers `true`. Declaring it says: this adapter stores a record whose
`metadata` holds the reserved key and nothing else, and it answers
`list_executions_by_metadata/2` and
`list_execution_states_by_metadata/2` for a match that names the reserved
key and nothing else. Host keys still need `metadata_supported?/1`. Four
facade answers read the new predicate:

| Facade surface | 0.25.1 requires | From this amendment on |
|---|---|---|
| `insert_execution/5` and `check_metadata/2`, the reserved key | `metadata_supported?/1` | `metadata_supported?/1` or `linkage_supported?/1` |
| `insert_execution/5` and `check_metadata/2`, any host key | `metadata_supported?/1` | unchanged |
| `child_listing_supported?/1` | the listing callback exported, and `metadata_supported?/1` | the listing callback exported, and `metadata_supported?/1` or `linkage_supported?/1` |
| `execution_states_supported?/1` | the projection callback exported, and `metadata_supported?/1` | the projection callback exported, and `metadata_supported?/1` or `linkage_supported?/1` |
| `list_executions_by_metadata/2`, `list_execution_states_by_metadata/2`, a match naming any host key | as the predicates above | `metadata_supported?/1` required, and refused as 0.25.1 refuses it on such a store |

A store whose adapter does not export `supports_linkage?/1` answers every
row above as it did on 0.25.1. The `Driver` doors keep reading the
predicates and nothing else: the single child's start and the
`:cancel_invoke` arm read `child_listing_supported?/1` (`start_child/3`
and `perform/5`), and `start_child_at/6` reads both predicates and
`execution_outcome_supported?/1` (`settleable/4`). On a store that
declares linkage, a durable child is created, listed, settled, cancelled
and answered through the same doors and the same code it takes on
Postgres. No refusal reason is added and none is removed.

**3. The shipped Ecto adapter gets a second home, and a host opts into
it.** The host module's `use StatifierPersistence.Ecto` options
(`StatifierPersistence.Ecto.Config`) gain one boolean, `linkage_columns:`,
which defaults to `false`. Migration version V09 adds six nullable columns
to the `executions` table: `linkage_parent_execution_id`,
`linkage_invoke_id`, `linkage_child_index`, `linkage_content_hash`,
`linkage_child_count` and `linkage_policy`, one per value under the
reserved key (the stored shape in `Linkage`'s moduledoc). It also adds two
indexes: one on `(linkage_parent_execution_id, linkage_invoke_id)`, which
serves the parent and invocation matches, and one on
`linkage_content_hash`, which serves the pin count. The `@migrations` map
holds versions 1 to 8 today (`lib/statifier_persistence/ecto/migrations.ex`),
so this is the next one. V09 reads and writes no row, and its `down/1`
drops the indexes and the columns. The execution schema the host module
generates names the six columns only when `linkage_columns: true`. A host
that leaves the option alone has a schema that names none of them, so
its adapter reads and writes exactly what 0.25.1 reads and writes, whether
or not V09 has run. Which home a row uses:

| Backend and option | `supports_metadata?/1` | `supports_linkage?/1` | Where a child's linkage is stored | How a linkage match is answered |
|---|---|---|---|---|
| Postgres, either value | `true` (unchanged) | `false` | Under the reserved key in the `jsonb` `metadata` column, byte for byte as 0.25.1 writes it | The `jsonb` containment SQL 0.25.1 issues, unchanged |
| Any other Ecto backend, `linkage_columns: false` (the default) | `false` (unchanged) | `false` | Where 0.25.1 stores it: in the `metadata` column, as the record the adapter is handed carries it | As 0.25.1 answers it: the facade refuses the listings for this adapter, and the adapter's own two listings answer `{:error, :metadata_unsupported}` |
| Any other Ecto backend, `linkage_columns: true` | `false` (unchanged) | `true` | In the V09 columns. The adapter writes no reserved key into the `metadata` column | Equality predicates on the V09 columns |

So a host that changes nothing sees 0.25.1's storage and 0.25.1's answers
on every backend. On Postgres the option changes nothing about where the
linkage lives. Only its schema names the columns, so a Postgres host that
sets it runs V09.

With the option on, off Postgres, the adapter splits the reserved key into
the columns on insert. On read it rebuilds the key from the columns when
`linkage_parent_execution_id` is set, and otherwise hands back the
`metadata` column as stored. The record it hands back therefore carries
the reserved key exactly as a Postgres store's record carries it. Every
write that carries the stored `metadata` forward carries the columns
forward. The one rewrite the sp-3l2a Amendment sanctions, the pin's
`content_hash` on a re-pin by `Executions.migrate_tree/4`, rewrites
`linkage_content_hash` for such a row (`linkage_update/3` in
`lib/statifier_persistence/storage/ecto.ex` is today's form, which rewrites
the `metadata` key). The adapter's pin count reads the same columns
(`child_pins/2`, same file, is today's `jsonb` form). Its "Off Postgres it
is `0`" sentence in `count_executions_by_content_hash/2`'s doc stays true
with the option off. With it on, the count is a count of the columns.

The columns are plain scalars rather than JSON text because equality on a
scalar is SQL that every Ecto backend parses. The containment the
`metadata` listings need is not (`supports_metadata?/1`'s doc says why),
and a JSON-path function differs from one backend to the next.

Postgres keeps the `jsonb` home for two reasons. Moving it would need a
backfill, plus a read that falls back to the key for any row written
after V09 by code older than V09. That is two predicates on the listing
the V03 GIN index now serves alone. And keeping it holds every Postgres
answer unchanged by construction: no Postgres SQL in the adapter changes.
Moving Postgres onto the columns is not decided here, and no bead asks for
it.

The second home is opt-in rather than a backend default because a host's
own adapter can call the shipped one. The reference embedder's SQLite
adapter, `StatifierExamples.Persistence`, delegates `insert_execution/2`,
`fetch_execution/2`, `update_execution/2` and `write_tree_migration/2` to
`StatifierPersistence.Storage.Ecto`, answers `supports_metadata?/1` with
`true` itself, and answers `list_executions_by_metadata/2`,
`list_execution_states_by_metadata/2` and
`count_executions_by_content_hash/2` by reading the `metadata` column
through its own schema (`lib/statifier_examples/persistence.ex` in
statifier_examples, read at `fc55a26`). If the shipped adapter moved the
linkage into the columns by backend, that embedder's delegated inserts
would leave the `metadata` column without the key its own listings and
pin count read. Its settlements, cascades and retirement pins would then
miss every new child, and its re-pins would leave the key it reads stale.

**4. Existing rows are read in place, on every backend.** Nothing is
migrated or backfilled, and no stored value is rewritten. A child that is
in flight when its host upgrades keeps its linkage where it is, and it
settles and answers as before. On Postgres that is the `jsonb` key. Off
Postgres, a row can hold a linkage only if the host's own adapter declared
`metadata` and stored it there, and the key stays in that `metadata`
column. Unlike V06 (its moduledoc's "What V06 does not rename: stored
child linkage", in `lib/statifier_persistence/ecto/migrations/v06.ex`),
this version needs no drain before the upgrade. V09 is needed only by a
host that sets `linkage_columns: true`. A host that does not may run it or
leave it, because its schema names none of the columns. A host on
hand-written DDL that opts in adds the columns itself, and
`expected_version/0` answers `9`.

**5. A host-written adapter needs no change, and neither does one that
delegates to the shipped adapter.** An adapter that answers
`supports_metadata?/1` with `true` and filters stored `metadata` by
`Linkage.reserved_key/0` keeps working on 0.26.0 unchanged, because the
seam it implements has not moved (point 1). When it delegates storage to
`StatifierPersistence.Storage.Ecto` as the reference embedder does, it
also keeps working, because with `linkage_columns:` left at `false` the
delegated callbacks store and read the reserved key in the `metadata`
column exactly as on 0.25.1. Such a host leaves the option off. Setting
it would move new children's linkage out of the column its own callbacks
read. An adapter that cannot store host keys but can store and match the
reserved key may now export `supports_linkage?/1` and host durable
children without declaring `metadata`. The upgrading page says all three.

**6. Serialization on such a backend is the host's strategy, as it
already is.** Answering a parent, settling a fan-out and the cascade each
run under the parent's or the child's exclusion. The default strategy,
`StatifierPersistence.Serialization.AdapterLock`, delegates to
`lock_execution/3`, which is Postgres SQL and raises elsewhere.
`docs/non-postgres-backends.md`'s "Declining the lock callback" already
tells such a host to pass its own strategy to `Driver.new/3` and to every
`Executions` call. This amendment changes nothing there. What it adds is
one consequence a host strategy has to bear: a child is created inside its
parent's serialization section (the sp-2yx Amendment above), so the
strategy is entered for the child's id while the parent's body is still
running. A pass-through strategy stays honest only for a single writer,
as that page says.

**7. A host can read an execution's active children.** The reader is
`StatifierPersistence.Executions.active_children/2`:
`active_children(store, execution_id)`. It answers
`{:ok, [StatifierPersistence.Execution.t()]}` with the direct children of
`execution_id`, across every invocation, whose stored status is not
terminal (`:active` or `:needs_migration`). The list is ordered by
invocation id, then by item index. It reads them through
`Storage.list_executions_by_metadata/2` over `Linkage.parent_match/1`,
the read `Executions.migrate_tree/4` already makes, so it works on every
store that answers `child_listing_supported?/1` and on both Ecto homes
alike. On a store that does not, it answers
`{:error, :child_listing_unsupported}`. It does not fetch the parent, so
an id with no children, stored or not, answers `{:ok, []}`. It reads one
level, and a host walks deeper by calling it again. It is read-only and
takes no exclusion: it reports what storage held when it read, like
`Storage.fetch_execution/2`. Nothing else is added to the vocabulary.

**8. The tests, and ADR-0005 decision 2.** The build proves the SQLite
half in the module `SqliteTestRepo` backs
(`test/statifier_persistence/ecto/sqlite_migrations_test.exs`), with that
module's `PassThroughSerialization` strategy. With `linkage_columns: true`
it asserts that a single child and a fan-out are created, listed,
settled, answered and cancelled there, and that V09's columns arrive.
With the option left at `false` it asserts that the module's existing
refusals still answer as they do on 0.25.1. The Postgres half is the
existing `DriverSubchartEctoTest` and `DriverFanoutEctoTest`, which must
stay green unchanged. This does not move ADR-0005 decision 2. That
decision chose the harness that proves the conformance suite and the lock
contract, and both stay on a real Postgres server: no SQLite case asserts
`lock_execution/3` or runs `StorageConformance`. The module already
proves behaviour on its own backend beside the migrations, in its "V05's
input log on this adapter" and "pruning finished executions on this
adapter" cases. The child cases are the same kind. The sp-y7n Note's
SQLite half ("The SQLite case therefore asserts what `driver:` has to be
there: inert") describes the code up to 0.25.1 and stays as written. From
the build on, that case asserts that an outside fail answers the parent
on SQLite when the option is on, and stays inert when it is off.

**What the record now decides.** Decision 2's linkage is still identity
data under the reserved key at every seam a host or an adapter sees. Its
storage home is the adapter's own choice. The shipped Ecto adapter stores
it in columns on a backend that cannot store `metadata`, but only for a
host that opts in with `linkage_columns: true`. Every other host keeps
0.25.1's storage. ADR-0006 decision 3 is narrowed by one optional
declaration: an adapter can host durable children without hosting a
host's `metadata`. No other decision in this record moves. The sp-3n2
Amendment's "still no join table" stands, because the columns sit on the
child's own row.

## Note (2026-11-19): the sp-lp5 Amendment is accepted

The 2026-11-19 sp-lp5 Amendment is accepted on 2026-11-19, under the
operator's standing grant to flip a record whose code has shipped. The
code that implements it landed in PR 297 (`b842b3f`, the option, V09 and
the adapter's second home), PR 298 (`1f3e8da`, the facade's linkage
predicate and the SQLite cases) and PR 299 (`bad360e`, the reader), and
shipped in statifier_persistence 0.26.0 (tag `v0.26.0`, `679802a`,
published on Hex 2026-11-19 by the release workflow). That Amendment's
own status line flips in place from proposed to accepted; its sentence
that it "is proposed until the code that implements it ships in a
published version and every claim below verifies against `main` at that
version" is met by this Note and stays as written, and the record above
stays accepted. Every cite below was read at `679802a`, the tag, which is
also `main`: no commit has landed on `main` since the tag.

What was re-read before the flip:

- **Point 1, the seam.** `lib/statifier_persistence/driver.ex`,
  `lib/statifier_persistence/execution/linkage.ex` and
  `lib/statifier_persistence/execution.ex` carry no change since `ce3cd44`;
  the adapter behaviour's one change is the optional
  `supports_linkage?/1` callback; `Linkage.from_metadata/1` is still the
  one reader of a stored linkage above the adapter.
- **Point 2, the facade.** `Storage.linkage_supported?/1` has
  `metadata_supported?/1`'s shape. `check_metadata_supported/2` admits a
  map holding the reserved key alone on such a store and refuses any host
  key; `child_listing_supported?/1` and `execution_states_supported?/1`
  read `linkage_storable?/1`; the two listings refuse any other match
  through `listing_open?/3`, asking `metadata_supported?/1` first. The
  `Driver` doors still read the predicates alone (`start_child/3`,
  `perform/5`, `settleable/4`).
- **Point 3, the second home.** `StatifierPersistence.Ecto.Config` takes
  `linkage_columns:`, a boolean defaulting to `false`; the generated
  execution schema names the six columns only when it is `true`
  (`table_fields/2` in `lib/statifier_persistence/ecto.ex`).
  `lib/statifier_persistence/ecto/migrations/v09.ex` adds the six
  nullable columns and the two indexes, touches no row, and its `down/1`
  drops both indexes and the columns; the `@migrations` map in
  `migrations.ex` now runs to 9, so `expected_version/0` answers `9`. In
  `lib/statifier_persistence/storage/ecto.ex`, `linkage_columns?/1` is
  true only with the option on and `supports_metadata?/1` false, so
  `supports_linkage?/1` is false on Postgres; `insert_execution/2` splits
  the reserved key into the columns (`split_linkage/1`), a read rebuilds
  it (`with_linkage/2`), the two listings answer by equality on the
  columns (`linkage_match/2`), `linkage_update/3` rewrites
  `linkage_content_hash` on a re-pin and `child_pins/2` counts the
  columns. The `jsonb` fragments the Postgres arms issue are the ones
  `ce3cd44` issued.
- **Point 3, the reference embedder.** `StatifierExamples.Persistence`
  at statifier_examples `0831aa3` still delegates `insert_execution/2`,
  `fetch_execution/2`, `update_execution/2` and `write_tree_migration/2`
  to the shipped adapter, answers `supports_metadata?/1` with `true`,
  and answers the two listings and the pin count itself.
- **Points 4 and 5.** Nothing in V09 or the adapter rewrites a stored
  linkage: `column_linkage_update/3` falls back to the `metadata` key
  for a row whose columns hold none. The "0.25 to 0.26" section of
  `docs/upgrading.md` says the three things point 5 names.
- **Point 6.** `StatifierPersistence.Serialization.AdapterLock` still
  delegates to `lock_execution/3`, and `docs/non-postgres-backends.md`
  carries "Declining the lock callback" and the consequence of a child
  created inside its parent's serialization section.
- **Point 7, the reader.** `Executions.active_children/2` lists through
  `Storage.list_executions_by_metadata/2` over `Linkage.parent_match/1`,
  keeps `:active` and `:needs_migration`, orders by invocation id then
  index, and fetches no parent;
  `test/statifier_persistence/executions_active_children_test.exs`
  carries its cases.
- **Point 8, the tests.**
  `test/statifier_persistence/ecto/sqlite_migrations_test.exs` carries
  the V09 columns, the option left off, the option on, and the durable
  children cases under `PassThroughSerialization`, with the outside fail
  answering the parent with the option on and inert with it off.
  `driver_subchart_ecto_test.exs` and `driver_fanout_ecto_test.exs` carry
  no change since `ce3cd44`.
- **The changelog.** The 0.26.0 section of `CHANGELOG.md` names the
  option, V09, the callback and predicate, and the reader under Added,
  and the facade's answers on such a store under Changed. It also names
  a `:supports_linkage?` call in the adapter telemetry off Postgres with
  the option off; no answer changes there, which is what point 3 says.

## Amendment (2026-11-22, sp-5pfj): every pass of a loop over a durable subchart gets a child of its own, and a re-drive of a pass still adopts that pass's child

Status of this amendment: proposed (2026-11-22, sp-5pfj). The record above
stays accepted; this amendment is proposed until the code that implements
it ships in a published version and every claim below verifies against
`main` at that version. Every cite below to code that predates this change
was read on `main` at `46746e4`; code this change adds is cited by name
alone.

Decision 3 creates a single child under one derived id,
`Linkage.child_execution_id/3`, the parent's execution id, the invoke id
and the index joined by `/` (`lib/statifier_persistence/execution/linkage.ex`,
read at `46746e4`). A create that answers `:execution_exists` is read as
ADR-0004 decision 3's at-least-once re-drive, and the existing child is
adopted when its linkage names the same parent and invocation
(`adopt_child/3` in `lib/statifier_persistence/driver.ex`, read at
`46746e4`). That reading assumed one invocation of an `<invoke>` element
per parent. A loop breaks it. A loop re-enters the invoking state, and an
`<invoke>` with an authored `id` keeps that id on every pass: the
interpreter generates an id only for an element that has none
(`generate_invoke_id/3` in statifier 2.15.0's
`lib/statifier/interpreter.ex`). So the second pass asked for the first
pass's id, adopted the first pass's finished child, and the parent waited
for an answer that had already been given. Ruled by the operator,
2026-11-22: the fix lives in statifier_persistence, recorded here with the
code, with no change to statifier_blocks.

**1. A pass is named by the parent's macrostep and round on the invoke
effect.** `Linkage.invocation/1` (in this change) writes
`"<macrostep>.<round>"` from the `macrostep` and `round` fields of the
`Statifier.Effect.Invoke` the interpreter emitted
(`lib/statifier/effect/invoke.ex` in statifier 2.15.0). Both counters are
part of the persisted position (`Position.to_binary/1` drops neither, in
statifier 2.15.0's `lib/statifier/position.ex`), so a re-drive, which
steps the same event from the same stored position, stamps the same two
values. A later pass cannot. Leaving the invoking state and entering it
again takes either a later macrostep (`begin_macrostep/1` raises the
count once per external event and resets `round` to 0) or a later round of
the same one, which is the case a macrostep's invoke pass re-entered after
an internal event makes possible; `round` is what tells those two apart,
and it is why the token is not the macrostep alone. The token is computed
from the effect the interpreter emitted, never from the effect a dispatch
handler answers with, so a handler that rebuilds the effect cannot change
it.

**2. The first pass keeps its id; a later pass's id extends it.** A single
child is still created under `Linkage.child_execution_id/3` on its first
pass, so a fresh child of an `<invoke>` outside a loop is stored under
exactly the id it was stored under before. That is deliberate: a host
derives that id to show or open a child (the reference embedder's
execution feed does, `child_execution_id/2` in statifier_examples'
`lib/statifier_examples/charts/durable.ex`, read at `44e6f4a`), and every child already stored keeps its id. A later
pass's child is created under `Linkage.child_execution_id/4` (in this
change), the first pass's id, then `@`, then the pass's token, for example
`loan_9/renewal/0@5.1`. It still strictly extends the parent's id, so the
acyclicity the cascade's termination rests on (decision 5) holds. The
linkage stored on every pass's child is the same four values a single
child's linkage has carried since the sp-3n2 Amendment: the pass is in the id, and nothing is added to the reserved map, to
the V09 columns of the 2026-11-19 Amendment, or to any adapter's schema.

**3. Which id a pass takes, and what it adopts.** A single child is read
for before it is created (`existing/2` and `create_child/6` in
`lib/statifier_persistence/driver.ex`, in this change):

| What the read finds at the first pass's id | What the pass does |
|---|---|
| nothing | creates its child there |
| a child linked to this parent and invocation that has not ended | adopts it: the re-drive of decision 3, as before |
| a child linked to this parent and invocation that has ended (`:completed`, `:failed` or `:cancelled`) | goes to its own id under point 2, and acts on what it finds there by the second table below |
| a child linked to anything else | refuses `:execution_exists`, as before |

| What the read finds at a later pass's own id | What the pass does |
|---|---|
| nothing | creates its child there |
| a child linked to this parent and invocation that has not ended | adopts it |
| a child linked to this parent and invocation that has ended with an answer its record holds (a recorded answer, or a failed child's `failure`) | adopts it and delivers that answer to the invocation it has just started, in the same drive (`adopt_later/2` and `recorded_answer/1`, in this change) |
| a child linked to this parent and invocation that has ended with no answer its record holds (a cancelled child, or a completed one on a store that keeps no answer) | refuses `:execution_exists`, which reaches the chart as decision 4's `child_execution_creation_failed` |
| a child linked to anything else | refuses `:execution_exists` |

A child that has ended at the first pass's id is an earlier pass's, never
this pass's re-drive in the ordinary case: the first pass's state is
entered again only after it was left, and leaving it either followed the
child's answer or cancelled the child through decision 5's cascade, which
reaches a parked child too (`Executions.cancel/3`'s documentation, read at
`46746e4`). A later pass's id carries its token, so a child found there is
that pass's, from a drive interrupted before the parent persisted.

**An answer reaches only the pass whose child it is.** The parent's door
reads liveness by invoke id alone (`late_answer/3` in
`lib/statifier_persistence/driver.ex`, read at `46746e4`), and a loop
reuses the invoke id on every pass, so that read cannot tell the pass the
parent waits on from any other. A single child's answer, from
`Driver.answer_parent/3` or the automatic answer, is now delivered only
when the answering child is the current pass's: the newest of the
invocation's children that the parent's stored position could have
started (`current_pass?/4`, in this change, read inside the parent's step
under its exclusion). The first pass's child is the oldest; a later pass's
child is ordered by its token; and a later pass's child whose macrostep is
after the stored position's own was started by a drive the parent never
persisted, so it is not counted. Any other single child's answer is
discarded, exactly as an answer to an invocation that is no longer live is
discarded today: `answer_parent/3` answers `{:discarded, execution}` and
the parent's position is untouched. The answer stays recorded on the
child's own record (the sp-51ah Amendment). An answer that names an
invocation rather than a child, through `Driver.done_invocation/5` or
`Driver.failed_invocation/5`, and a fan-out's settled answer, keep the
invoke id's liveness read alone. If the listing of the invocation's
children fails, the invoke id's liveness read alone decides, as before
this change.

So, case by case:

| Case | What happens |
|---|---|
| An earlier pass's answer, delivered again after the next pass started | discarded; the parent and the next pass's child are unchanged |
| A later pass's child created by an interrupted drive, which ends before the re-drive | its answer is discarded (its macrostep is after the stored position's); the re-drive of that pass adopts it and delivers its recorded answer, by the second table |
| A first pass's child created by an interrupted drive, which ends before the re-drive | its answer is discarded, as on `0.26.0` (the stored position holds no live invocation of that id); the re-drive finds it ended at the first pass's id, reads it as an earlier pass's, and creates a later pass's child. **The cost this amendment accepts: that child's work runs twice.** The first pass's id carries no token, so this child cannot be told from an earlier pass's ended child; adopting it instead would leave the parent waiting for an answer already discarded |

The read comes before the create, rather than the adoption read after a
refused create, because on Postgres the refused insert aborts the parent's
own lock transaction, and nothing can be read inside it afterwards; on
`0.26.0` a re-drive that found its child already created there raised
`in_failed_sql_transaction`. The parent's own exclusion is what keeps the
read and the create together: nothing else creates a parent's single
child. A fan-out's child, created outside the parent's step by
`Driver.start_child_at/6`, keeps the create-then-adopt order.

**4. The exit of a pass cancels that pass's child, not the next one's.**
A loop's exit from the invoking state and its entry again land in one
step, so a re-drive of that step runs decision 5's cancel for the
invocation being left before the invoke of the new pass. Decision 5's walk
matches every child of the invocation's id (`Linkage.invocation_match/2`),
which would also reach a later pass's child that the interrupted drive
had already created, and cancel the child the re-drive is about to adopt.
So the `{:cancel_invoke, _}` arm now spares a later pass's child whose
token is at or after the cancel effect's own macrostep and round
(`started_before?/3` in `lib/statifier_persistence/driver.ex`, in this
change), through an internal narrowing of the walk's first level
(`Executions.cascade_cancel_where/4`, undocumented, in this change).
Everything that walk reached before is still reached: the first pass's
child, a fan-out's children, and a later pass's child whose token is
earlier than the cancel's. `Executions.cascade_cancel/3` is unchanged.

**5. Nothing stored before this change moves.** A row written by `0.26.0`
or earlier sits at the first pass's id with the same four linkage values,
and point 3 reads it by the same rule: a child still running is adopted,
answered and cancelled as before. No migration version is added, no
stored value is rewritten, and a storage adapter a host wrote against
`0.26.0` sees the same records, the same matches and only execution ids of
a new shape, which an adapter already stores as opaque strings.

**6. A fan-out is not decided here.** `Driver.start_child_at/6`, its
children's ids under `Linkage.child_execution_id/3`, its adoption rule and
its settlement are unchanged. A fan-out whose invoking state a loop
re-enters still asks for the first pass's ids; that is left to a later
record.

**What a host sees.** Two functions are added,
`Linkage.child_execution_id/4` and `Linkage.invocation/1`, and a host that
derives a later pass's child id uses them with the pass's invoke effect.
`[:statifier_persistence, :child, :started]` carries the id the child was
created or adopted under, a later pass's included; no event, key or value
is added. The read of point 3 is an adapter call like any other, so
`[:statifier_persistence, :adapter, :call]` now reports a
`:fetch_execution` before a single child's `:insert_execution`, with
`outcome: :error` and `reason: :execution_not_found` when the id is free,
which is the ordinary case; a later pass reports one such read for each id
it tries. A single child's answer adds one
`:list_executions_by_metadata` call, the current-pass read. The changelog
fragment names these under Added, Changed and Fixed.

Choices weighed and not taken:

- **A count of the starts of an invoke id, kept per parent.** A count read
  at the start of a pass is the same on the pass that follows a finished
  one and on the re-drive of a pass whose child was created before the
  crash, so it cannot tell them apart without a second stored mark.
- **The token stored in the linkage.** Exact for every pass, first
  included, but the V09 columns hold exactly six values
  (`@linkage_columns` in `lib/statifier_persistence/storage/ecto.ex`, read
  at `46746e4`), so it needs a seventh column and a migration
  version for a host with `linkage_columns: true`, and it changes the
  stored map a host adapter reads.
- **Every single child under a token id.** Exact for every pass too, but it
  moves the id of every fresh single child, which hosts derive today.
- **An invoke id generated per pass by the compiler.** A statifier_blocks
  change, which the ruling above rules out.

Where this is proved:

| Store | Two passes, in order, the parent goes on | A re-drive of the second pass adopts its child |
|---|---|---|
| In-memory adapter | `driver_subchart_loop_test.exs` | `driver_subchart_loop_test.exs` |
| Ecto adapter on Postgres, under `AdapterLock` | `driver_subchart_ecto_test.exs` | `driver_subchart_ecto_test.exs` |
| Ecto adapter on SQLite, `linkage_columns: true` | `ecto/sqlite_migrations_test.exs` | `ecto/sqlite_migrations_test.exs` |

`driver_subchart_loop_test.exs` also carries a loop left mid-pass twice,
which cancels the first pass's child and then a later pass's.
`driver_subchart_loop_test.exs` and `driver_subchart_ecto_test.exs` each
carry the first two rows of the case table above: an earlier pass's
answer delivered again is discarded, and a later pass's child that ended
before the re-drive answers the pass that adopts it.
`driver_subchart_ecto_test.exs` also carries a single child's re-drive on
Postgres; `execution_linkage_test.exs` carries the two new functions. All
paths are under `test/statifier_persistence/`.

No other decision in this record moves.
