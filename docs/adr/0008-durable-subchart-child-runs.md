# ADR-0008: A durable subchart's child is an ordinary run, linked by pinned metadata, started and answered across the async seam, and ended by a cascading cancel that retains

Status: proposed (2026-09-01; drafts the durable-subchart rulings recorded on
sp-nt8 and its mirror sb-2i04, 2026-08-31)

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
