# ADR-0007: A durable run can rest mid-invocation: the pending dispatch arm, the two re-entry doors, and `active_invocations` as the race mechanism

Status: accepted (2026-09-01, campaign-024 ruling R-c; unqualified direction-agent verdict)

## Context

`StatifierPersistence.Driver` answers every `<invoke>` inside the durable
step that emitted it. Its `dispatch` fun returns `{:ok, donedata}` or
`{:error, failure}`, both of which are answers, and the drive buffers each
one and steps it back before returning. That shape is right for a call the
host can make and complete in the same breath - an HTTP request, a
function call - and it is the shape the run-to-quiescence loop was built
around.

It has no arm for the call that does not complete in the same breath. A
host that enqueues a job, calls a service that answers by webhook, or hands
the work to another node has nothing to return: the call has *started*, and
the answer will arrive minutes or days later, from a process that does not
exist yet, quite possibly after a deploy. Today such a host has two bad
options - block the drive on the result, which defeats the point of a
durable run, or invent an answer, which lies to the chart.

Even with a way to say "started", there was no public door to answer
through. `Driver`'s event construction is private, and
`Statifier.Session.done_invocation/3` and `failed_invocation/3` need a live
session process, which the durable path deliberately does not have. A host
would have had to hand-build `done.invoke.<id>` and
`error.communication.invoke.<id>` events and push them through
`send_event/4` - reconstructing `origin`, `origintype`, `invokeid` and
st-ADR-0068's three-key failure payload by hand, which is exactly the
non-conformance this driver was written to delete.

The hard part is not either door. It is the race between them. An
invocation the chart cancels - by taking a transition out of the invoking
state, a timeout being the ordinary case - has an answer still coming for
it, and the answer arrives on a node that has never seen the run. Spec
6.4.3 says such an answer is discarded at drain time, and the in-drive loop
already implements that (`Driver.live?/2`). The question this record
answers is what the *durable* path reads to make that decision, and where.

The bead (sp-e50) framed the design question the operator's ruling then
handed back to this plan: is the persisted `active_invocations` map enough,
or does the durable path need an in-flight-invocation record of its own?

## Decision

**1. `:pending` is a third arm of the dispatch fun.** A `dispatch` that
returns `:pending` has *started* the call and will answer it later. Nothing
is buffered for it; the drive reaches quiescence and the position persists
with the invocation live in `machine_state.active_invocations`. No process
holds the run in the meantime, which is the property that makes the arm
worth having: the run can wait days and survive a deploy, which is what
this package exists for.

**2. Completion re-enters through two public doors, named for
`Statifier.Session`'s.** `Driver.done_invocation/5` and
`Driver.failed_invocation/5` take the run id, the invocation id and the
outcome, and build the same two events the in-drive path builds - from the
same `Statifier.Evaluator.SystemVariables` writers, from the run's own
persisted `_sessionid`, with st-ADR-0068's `:reason`/`:attempts`/`:detail`
payload on the failing side. A host never constructs an event. The failing
door means *permanently* failed in st-ADR-0068's sense; a transient failure
is the host's to retry before answering.

**3. The race is decided by `active_invocations`, read inside the run's
serialization strategy.** There is no new in-flight record. `Statifier.
Position` already persists `active_invocations` across a restart, and
`Statifier.Interpreter.ExitEntry` removes an entry when the invoking state
is exited - which is what a cancel is. A door therefore reverse-looks-up
the invocation id in that map and discards when it is absent, returning
ADR-0004 decision 3's own `{:discarded, run}`. The criterion under which
that outcome was allowed is campaign-024 ruling R-c's rider, which made a
cancel-versus-completion-across-restart conformance test a hard acceptance
criterion and permitted an in-flight-invocation record only if that test
forced one: the test is
`test/statifier_persistence/driver_restart_race_test.exs`, and it passes
against the persisted map alone, so no record proved necessary.

The read is taken *inside* `with_run/3` (ADR-0004 decision 5), not before
the call. A door that loaded the position, checked liveness and then called
`Runs.step/5` would leave a window for a cancel to land between the read
and the step, and `Statifier.Interpreter` would not catch it: a
`done.invoke` whose `invokeid` is not live is not dropped by the core, it
merely skips the finalize and autoforward passes and still drives ordinary
transition selection. The liveness read is this package's to make, and it
has to be made under the same exclusion as the step it gates.

**4. `Runs.step/5` gains an event-builder arm to carry that.** Its `event`
parameter becomes `Event.t() | event_builder()`, where a builder is a fun
over the loaded, re-stamped `MachineState` returning `{:ok, event}` or
`:discard`. Every existing caller passes an `%Event{}` and is unaffected.
This is additive to ADR-0004 decision 3's order, not a reordering of it:
the named steps still run liveness check -> load -> re-stamp -> step ->
effects -> status -> persist, and the builder only late-binds the event
argument to the step that was already going to happen. A decline writes
nothing and executes nothing, so it is a discard in the full sense.

**5. The dispatch context carries `invoke_id`.** An asynchronous host
cannot key its job without the invocation's id, and it is the same string
the doors take back. It is a `Driver.dispatch_context/0` and not a widening
of `StatifierPersistence.Executor.context/0`, because it is not a property
of the run or the step: it names one `<invoke>`, and only the dispatch fun
is called once per invocation.

## Consequences

Re-entry is idempotent for the ordinary chart - the one that transitions
out of the invoking state on its answer - because the second delivery finds
the invocation gone. It is **not** idempotent for a chart that stays in the
invoking state after answering, because the core removes an entry from
`active_invocations` on exit and on nothing else. That is the in-drive
path's behavior too, not something the doors introduce, and it is the one
place where a host redelivering a completion (an at-least-once job queue
retrying, say) must supply its own delivery-once discipline. Curing it here
would mean this package writing to `active_invocations` from outside the
interpreter, which is statifier-ex's contract and not ours to edit; if the
gap turns out to bite a real embedder, the fix is a request upstream, not a
local deviation.

A discard is `{:discarded, run}` and not a distinct arm, so a host that
wants to tell "the invocation was cancelled" from "the run was already
over" reads the returned run's status rather than the tuple. Both mean the
same thing to a job: do not retry, nothing to do.

`:pending` puts the responsibility for eventually answering squarely on the
host. A host that starts a call and never answers it leaves a run resting
forever with a live invocation - the durable equivalent of a leaked
process. That is deliberate: this package holds no timers (they are
statifier_oban's, per st-ADR-0054), so a deadline on an asynchronous call
is a `<send delay>` in the chart or a scheduled job in the host, and the
cancel path this record makes safe is exactly how such a deadline ends the
invocation.

Nothing about identity, serialization or the guard moves. A pending
invocation is persisted by the same `Statifier.Position` encoding as any
other, under the same content-hash guard (ADR-0003, st-ADR-0052), and a
run answered on a node running a different chart revision is refused at
load as it always was.

## Amendment (2026-09-01, sp-2yx): decision 5's dispatch context also carries the effect

Decision 5 put `invoke_id` on `Driver.dispatch_context/0` and stopped
there, on the reasoning that `type` and `params` are already arguments and
an asynchronous host needs nothing else to key its job by. That is true of
the host decision 1 was written for. It is not true of a host that has to
*resolve* what the invocation names: `Statifier.Effect.Invoke`'s `src` -
spec 6.4's URI attribute, which the core never dereferences (st-ADR-0031)
- is the only field carrying a document id, and no argument and no context
key delivered it. A `statifier_blocks` durable subchart handler resolves
its child chart by exactly that id (`sb-ADR-0008` decision 2), and could
not.

So the context gains one key, `invoke`, holding the whole
`t:Statifier.Effect.Invoke.t/0` the dispatch is for. It is the same
reasoning decision 5 already gave, applied to the rest of the element: a
property of the one `<invoke>` rather than of the run or the step, so it
belongs on the dispatch context and not on
`StatifierPersistence.Executor.context/0`, which every effect shares.

The widening is additive and nothing else moves. `type` and `params` stay
their own arguments - they are what an ordinary host acts on, and making a
host reach into a struct for them would be a worse seam for the common
case. `invoke_id` stays too, rather than becoming `invoke.invoke_id`: it is
the string the two doors take back, decision 5's own words, and every
existing dispatch fun matching `%{invoke_id: id}` keeps matching. A fun
that ignores the new key is unaffected, because a map pattern binds what it
names.

What the key deletes is a lie the durable path told. Before it, a subchart
handler answering `{:start_child, invoke, {:invoke, invoke}}` had to
*synthesise* that `%Invoke{}` from an id plus content it already knew,
which works only for a host that hardcodes one chart per invoke type.
`Driver.dispatch/0`'s claim that "a host never has to build this tuple
itself: a subchart handler returns it unchanged from what it received" is
now literally true, which is what ADR-0008 decision 3's portability
argument assumed all along.
