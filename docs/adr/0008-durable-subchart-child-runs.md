# ADR-0008: A durable subchart's child is an ordinary run, linked by pinned metadata, started and answered across the async seam, and ended by a cascading cancel that retains

Status: accepted (2026-09-01, campaign-025; unqualified direction-agent
verdict; drafts the durable-subchart rulings recorded on sp-nt8 and its
mirror sb-2i04, 2026-08-31)

## Context

`statifier_blocks` ships the canonical subchart invoke handler
(`StatifierBlocks.Runtime.Subchart`, campaign-023). Its `start/2` is a pure
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
existing convention into contract. Campaign-023's R-d treated a recorded
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
operator's campaign-026 ruling `R26-5`.

Two accepted records depend on what follows and are cited rather than
restated:

- `statifier_blocks` **ADR-0009**, *durable fan-out is a new block type,
  `core.map`* (accepted 2026-09-01, campaign-026). Its decision 10 cites
  this amendment for the linkage widening, and it depends on exactly one
  thing from it: that the item index reaches the child's own metadata, so
  that its decision 5's index-ordered accumulation is recoverable when
  completions arrive out of order, after a restart, on a process that did
  not exist when the child started.
- `statifier_oban` **ADR-0007**, *fan-out child starts are batched*
  (accepted 2026-09-01, campaign-026). Its decision 5 derives a fan-out's
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

**Nothing here is implemented.** Campaign 026's `R26-1` defers the
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
Campaign 031's fan-out proof hit exactly that and worked around it
host-side, translating the condition through the public
`StatifierPersistence.Driver.answer_parent/3`.

This amendment closes that seam, per the operator's campaign-033 ruling of
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

**Proposed, not accepted, and not implemented.** This amendment carries no
`lib/` change and no test, in the same posture the sp-3n2 amendment above
records for itself. `sp-hia` implements it - the `run_status/2` arm, the
`failure` string, and a case that drives a failure-classed final through a
`:first_error` fan-out - and this section's acceptance is recorded
separately once that lands.
