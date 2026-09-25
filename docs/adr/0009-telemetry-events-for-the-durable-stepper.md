# ADR-0009: Telemetry for the durable stepper: `:persistence` on the family contract, plus a storage-phase family of this package's own

Status: accepted (2026-09-01, sp-i21; unqualified direction-agent verdict)

## Context

`st-ADR-0062` rules that the OpenTelemetry bridge is one separate package,
`opentelemetry_statifier`, consuming public `:telemetry` events only, and
`statifier-ex`'s `docs/opentelemetry.md` "What lands where" table assigns
this repository two distinct pieces:

| Piece | Where |
|---|---|
| Sibling-package telemetry surfaces and their bridge halves | each sibling repo's own ADR, bridged in `opentelemetry_statifier` |
| Durable-driver emit sites: calling `Statifier.Telemetry` at the stepper seam, with its own `driver` atom | `statifier_persistence` (own repo, own ADR, per `st-ADR-0067` decision 3) |

That second row is what makes this package's shape different from every
other sibling's, and it is the fact this record is organized around.
`st-ADR-0067` observed that the durable path - decode a position, call an
advance entry, execute the effects, persist - is a fully supported second
stepping driver that emits nothing, so a run stepped here is invisible to
the bridge while the same chart in a `Statifier.Session` is fully observed.
Its decision 2 moved the emitters into a caller-agnostic
`Statifier.Telemetry` **so that this package would not hand-roll a second
implementation of a 27-name contract**; its decision 3 tabulates which of
those events a process-less driver emits; its decision 4 adds a `driver`
atom to every event's metadata and leaves the choice of this driver's atom
to this repository; and its decision 6 draws the line: interpreter
semantics stay in `[:statifier, :session, ...]` whatever the driver, and
"everything about how a position got into memory and back out is the
driver's own surface", naming `[:statifier_persistence, ...]` as where that
surface belongs.

Today this package emits nothing at all. There is no `:telemetry`
dependency in `mix.exs`, no `:telemetry.execute/3` call anywhere in `lib/`,
and the only mentions of the word are three pieces of prose that assume a
host will do it (`Executor`'s `t:context/0` typedoc - "enough to key
idempotency storage and telemetry without another lookup"; ADR-0004's note
that structured failure detail "belongs in host telemetry").

The sibling that went first is `statifier_oban`, whose `sob-ADR-0006`
landed hours before this one and set two precedents for the family: the
`[:package_name, ...]` prefix, and `scope` rather than `session_id` as the
identity key where a run outlives any live session. Its Consequences
invite a sibling with a genuinely different shape to say so rather than
copy out of deference. This record accepts the first precedent, departs
from the second with grounds, and departs from a third (its
no-`:start`/`:stop` rule) with grounds, because the reason `sob-ADR-0006`
gave for each does not hold here.

Facts about this package that bound the answer:

- **The identity vocabulary is `run_id`, and `session_id` is not free.**
  `run_id` is the caller-supplied storage key, present in `Executor`'s
  `t:context/0`, in the driver's `t:dispatch_context/0`, on `Run.t()`, and
  on every `Runs` and `Storage` entry point. `session_id` is two different
  things here: the positions table's key, which no run-lifecycle function
  takes, and the chart's own `_sessionid` inside the persisted datamodel,
  which the driver already reads privately for event origin. The runs
  table's `session_id` column exists and is deliberately unpopulated by
  library code (ADR-0002 decision 5). So a run's logical session id is
  knowable only *after* the position has been decoded.
- **This package genuinely owns intervals.** The serialized unit - acquire
  the per-run exclusion, fetch the record, decode and identity-check the
  position, call the interpreter, execute every effect through the host
  executor, derive status, persist - is bracketed by nothing else in the
  family. Neither Oban nor upstream can time it, and the upstream
  macrostep span covers only the advance in the middle of it.
- **The failures worth counting are refusals, not exceptions.** The
  identity guard's `{:identity_mismatch, stored, supplied}` and
  `:unidentified_chart` (`Storage.precheck_identity/2`, and every writer),
  the adapter capability refusals `:metadata_unsupported` and
  `:child_listing_unsupported`, the terminal-run discard, the event
  builder's decline, the `{:error, :not_running}` record repair, the
  executor failure that re-enters as `error.communication` (ADR-0004
  decision 4), and `{:turns_exhausted, n}`. Every one is an ordinary
  return value that no exception tracker will ever see.
- **Two things on a run record are hazardous to emit.** The `metadata` map
  is host-opaque host identities and, by ADR-0006 decision 2, sits at rest
  in the clear outside `:blob_type` encryption; the chart, position and
  identity blobs are opaque and may be encrypted. Neither belongs on an
  event in any form.

## Decision

### 1. This package emits `:telemetry` and never touches an OpenTelemetry API

Span creation, handler attachment, context restoration and the span table
are `opentelemetry_statifier`'s, per `st-ADR-0062`. This package takes no
`opentelemetry_api` dependency in any environment. It does take a direct
`{:telemetry, "~> 1.3"}` dependency, which it does not have today: the
transitive one through `statifier` is not a contract, and a package that
calls `:telemetry.execute/3` declares it.

This package's half of the bridge is a specification obligation - that the
events carry everything the bridge needs, so the bridge never reads a blob,
a run record, or `StatifierPersistence.Run.Linkage` - discharged by
`docs/telemetry.md`, which is the full contract. This record fixes the
decisions that document rests on.

### 2. The stepper seam emits the `[:statifier, :session, ...]` family through `Statifier.Telemetry`, and the driver atom is `:persistence`, frozen

Adopted from `st-ADR-0067` decisions 2 and 3, without variation. This
package does not define its own macrostep or effect events; it calls the
same functions `Statifier.Session` calls, so a durably-stepped macrostep is
structurally the same family as a session-stepped one rather than a
look-alike.

`st-ADR-0067` open question 1 leaves the atom to this repository and
suggests `:persistence`. **The atom is `:persistence`**, and it is frozen
under decision 8's amendment discipline from the first release that emits
it. The bare-noun form matches upstream's reserved `:session` and names the
driver's role rather than this package's name; the package name is already
carried, unambiguously, by the second family's prefix (decision 3).

Applicability follows `st-ADR-0067` decision 3's table exactly, and the
three non-obvious rows are restated here because they are this package's
to get right:

- **`:init` fires once per logical run, at `Runs.create/4`**, around the
  `Interpreter.initialize/2` call, with `resumed: false`. It never fires on
  a load. Every `Runs.step/5` here is a rehydration, and an `:init` per
  load would fire thousands of times per run and would mean "process boot",
  which does not exist on this path.
- **`:terminate` is never emitted.** It names a GenServer callback. Both
  halves of every span this package opens arrive inside one synchronous
  call, so there is no open-span entry for the bridge to leak.
- **`:interpret` is never emitted**, because this package has no
  `st-ADR-0029` injection seam. If it grows one it emits that same event
  rather than minting a name, per `st-ADR-0067` decision 3.

`:unroutable` **is** emitted, and this record fixes which case it names,
because upstream's phrase ("an effect the driver could not route") maps to
two different returns here. It names an effect this package could not hand
to anything - no dispatch arm and no executor accepted its kind. An
executor that accepted the effect and returned `{:error, reason}` is a
*failure*, not an unroutable effect: it is reported by
`[:statifier_persistence, :effect, :failed]` (decision 4) and it re-enters
the chart as `error.communication` per ADR-0004 decision 4.

The `session_id` these emitters require is the `_sessionid` the driver
already reads out of the decoded datamodel. This package performs no extra
lookup to obtain it and never invents one: an emission site that does not
have a decoded position does not emit an event that needs it.

### 3. The storage-phase family is `[:statifier_persistence, ...]`, fixed and not configurable

Adopted from `st-ADR-0067` decision 6, which names this namespace, and
aligned with `sob-ADR-0006` decision 3, which established the per-package
prefix as the family pattern. It is not configurable, for that record's
reason: the bridge must name the events at compile time to attach per
event name, and a per-host prefix would make its attach list depend on
host configuration it cannot see.

**Fourteen events**, listed with their measurements and metadata in
`docs/telemetry.md`, covering exactly four things and nothing else:

1. **The durable step as an interval** - the serialized unit that brackets
   the interpreter call, and the per-run exclusion wait ahead of it.
2. **The storage phases** - each adapter callback with its latency and its
   outcome, and the identity guard's refusals.
3. **This package's own verdicts on a run** - created; terminated
   (including the two host-driven terminations `Runs.fail/4` and
   `Runs.cancel/3`, which involve no interpreter and about which upstream
   therefore emits nothing at all); discarded; the executor failures that
   re-enter as `error.communication`; and `Driver`'s
   `{:turns_exhausted, n}`, which is the drive loop's own refusal and is
   reported as a point-in-time verdict rather than a span (decision 5).
4. **The durable-subchart seam** (ADR-0008) - a child started, a start
   refused, a child answering its parent, and a cascading cancel's sweep
   count.

Deliberately absent: the interpreter's own semantics, which are decision
2's family and are not re-emitted here; any wrapping of `Executor.execute/2`
beyond its pass/fail verdict, because the host's work is the host's to
instrument; and any event for the Ecto layer's own SQL, which is
`opentelemetry_ecto`'s and is already emitted with the full query.

### 4. The identity key is `run_id`; `session_id` rides where a position has been decoded; there is no `scope`

This is the deliberate departure from `sob-ADR-0006` decision 6, and the
grounds are that its reasoning does not transfer rather than that this
record disagrees with it. `StatifierOban.Timer.Key`'s scope is *either* a
session id *or* a host run id and the package cannot tell which, so
`scope` is the only honest name available there. Here both exist as
distinct, named things: `run_id` is this package's own storage key on every
seam, and the logical `_sessionid` is upstream's correlation key carried in
the position blob. Calling either of them `scope` would discard information
this package actually has, and the family gains nothing from a shared name
that means a different thing in each package.

So: every event in the `[:statifier_persistence, ...]` family carries
`run_id`. It carries `session_id` **only where the position has already
been decoded** - `nil`, explicitly, on the events emitted before or instead
of a successful load - and never as the result of a lookup performed to
fill the field in. `content_hash` rides where a chart identity is in hand,
because it is the chart-revision key both this package and the host already
use.

Nothing changes on the decision-2 family: `st-ADR-0067` decision 4
considered and rejected putting a storage-level run key on it, and this
record does not reopen that. The two families join for a consumer the same
way their spans do - by being emitted inside one synchronous call, so the
bridge nests them by ordinary ambient context, and by `session_id`, which
`docs/telemetry.md` requires the bridge to map onto the same
`statifier.session_id` attribute upstream uses.

### 5. The step seam is a `:start` / `:stop` pair; everything else is a point-in-time event

The second deliberate departure from `sob-ADR-0006` (its decision 5,
no pairs), and again because its grounds do not transfer.
`statifier_oban` owns no interval that Oban does not already own, so a pair
there would produce two timings for one interval. This package owns an
interval nobody else measures at all - lock, load, decode, advance,
execute, persist - and the upstream macrostep span is expected to appear
*inside* it (`st-ADR-0067` decision 6). Ambient-context nesting requires an
outer span that is genuinely open during the inner one, which a
single event carrying a duration cannot provide.

`span_ref` keeps `st-ADR-0040` decision 2's semantics verbatim: a fresh
`make_ref/0` per span, carried on both halves, the only pairing key. Both
halves are emitted inside one function call, so `st-ADR-0067` decision 5's
constraint - a span never crosses a persist boundary - holds structurally
rather than by discipline.

The adapter events are **not** pairs. They carry `duration` as a
measurement, the way `opentelemetry_ecto` reports a query, because nothing
nests inside a storage call and a pair would double the event count on the
hottest path in the package for no consumer's benefit.

Rejected alternative: a third, outer pair bracketing `Driver`'s turn loop,
so a multi-turn drive would nest its steps. The loop is one turn in the
ordinary case, which would make the outer span a duplicate of the inner one
almost always, and the one fact the loop has that a step does not -
exhausting `max_turns` - is a single point-in-time verdict that
`[:statifier_persistence, :drive, :turns_exhausted]` reports without a
span. A multi-turn drive therefore produces sibling step spans under
whatever the caller's ambient span is, which is honest about what happened.

### 6. Resume linking is answered, and the answer is that nothing trace-shaped goes in the position blob

sp-i21 asked how a resumed session's spans relate to the run that persisted
the position, and floated span links carried through the position blob's
metadata - flagging that this interacts with `st-ADR-0052`/`st-ADR-0060`
and should be decided before the blob format calcifies. It is decided, and
the answer is **no**, on four independent grounds:

1. **There is nothing span-shaped to serialize.** `span_ref` is a
   `make_ref/0` - node- and VM-local, meaningless on the node that reads it
   back. `st-ADR-0067` decision 5 already draws the conclusion: a macrostep
   span never crosses a persist boundary.
2. **The blob format is not this package's to extend.** Serialization is
   `statifier-ex`'s contract (`st-ADR-0052`/`st-ADR-0060`, and the
   family's contract-ownership rule). Adding a trace slot would be this
   package deviating from a contract it defers to, which is the exact
   failure this repository's CLAUDE.md names.
3. **The carrier already exists and it is not the blob.** `st-ADR-0063`'s
   `caller_context` is an opaque host slot riding the *event*, in W3C text
   form, and it reaches `[:statifier, :session, :macrostep, :start | :stop]`
   as metadata on the step it drives. A durable timer firing three days
   later links to the trace that armed it through that slot
   (`sob-ADR-0006` decision 7), and a durable step driven by any other
   external event links the same way.
4. **This package's one durable host slot is the wrong place.** ADR-0006's
   `metadata` map is host-owned, identities-only, write-once at create, and
   outside `:blob_type` encryption. The only reserved key in it is
   `"statifier_persistence"`, reserved for ADR-0008 linkage, and this
   record does not reserve a second one.

**What a consumer therefore gets.** Within a node, consecutive macrosteps
of one run stitch through the bridge's own last-span-context table, keyed
on `session_id`, exactly as statifier-ex's `docs/opentelemetry.md` already stitches
session macrosteps - the durable case is not special. Across a node
boundary or a deploy, where that table misses, a step links to its driving
trace if and only if the host attached a `caller_context` to the driving
event; with none, each macrostep is an unlinked trace, correlated by the
`statifier.session_id` attribute rather than by parenthood. That is the
standard detached case, not an error, and it is the same behavior upstream
has.

**Deferred, with an explicit trigger.** Whether this package reserves a
second key under its linkage namespace - a `"statifier_persistence.trace"`
carrying a W3C `traceparent` written at create - so that cross-node resumes
link without host cooperation. The trigger to reopen is a host
demonstrating a resumed run it cannot stitch **where the miss is the
cross-node / last-span-table case and no `caller_context` was available**;
a host that simply did not attach one has a fix that needs no record. The
disclosure hazard ADR-0006 decision 2 exists for does not bite this
particular value - a traceparent is a trace id and a span id, not personal
data - so the deferral is on need, not on safety, and the trigger should be
read that way.

A child run (ADR-0008) is a separate run with its own logical session, so
the same rule applies to it: its macrostep spans are not parented by the
parent's dispatching span, which would hold the parent's trace open for the
child's whole life. `[:statifier_persistence, :child, :started]` carries
`parent_run_id`, `child_run_id`, `invoke_id`, `child_index` and the child's
pinned `content_hash`, which is everything the bridge needs to link the two
without reading `Run.Linkage` or a metadata map.

### 7. Nothing host-opaque, nothing from the datamodel, and no run metadata is ever on an event

A hard rule, stated in decision form because a host cannot infer it from
the API's shape. Never emitted, in any form - not truncated, not hashed,
not "just the keys": the `chart_blob`, the `position_blob`, the
`identity_blob`, the ADR-0006 `metadata` map, the chart's datamodel, an
invoke's `params`, and a `:done` effect's `donedata`.

The identity guard's refusal is the sharp case, because its error term
carries two whole `Identity` structs. The event carries the two
`content_hash` values and nothing else from them: a content hash is a
digest of a chart document, it is the key this package and the host already
exchange, and it is what makes a deploy-drift alarm actionable. The
envelope around it is not.

`metadata` is the case a well-meaning implementer will get wrong. It is
tempting as a metric dimension - it holds exactly the tenant and
correlation ids an operator wants to slice by. It is excluded anyway: it is
unbounded by construction, it is host-defined so no cardinality budget can
be reasoned about here, and ADR-0006 decision 2 already records that it is
at rest in the clear regardless of `:blob_type`. A host that wants to slice
its own telemetry by its own tenant id has the run id on every event and
its own table to join against.

The one unbounded value on any event in this family is `run_id`, which is
host-supplied and is present as a correlation id for a span or a log line,
never as a metric dimension - the same status `job_id` has in
`sob-ADR-0006` and Oban's own `id` has in Oban.

`caller_context` does not appear in this family at all. This package
originates none; it rides the decision-2 family from the driving event,
where `Statifier.Telemetry` puts it, and the bridge reads it there.

### 8. `StatifierPersistence.Telemetry` owns the names, `events/0` returns them all, and the contract is amended in place

One definition site, module attributes holding literal atoms, no name
segment ever derived from a module name at runtime, and
`StatifierPersistence.Telemetry.events/0` returning the full list. This is
what `ots-ADR-0003`'s attach-one-handler-per-event-name mechanism needs and
what `Statifier.Telemetry.events/0` and `StatifierOban.Telemetry.events/0`
have already set as the family's precedent; Credo's `UnsafeToAtom` rules
out the runtime-derived alternative independently.

The module also owns the emitters, so that no call site anywhere in `lib/`
constructs an event name or a measurement map inline. `Statifier.Telemetry`
calls for the decision-2 family are made from the stepper seam directly and
are not wrapped: a wrapper would be the second implementation
`st-ADR-0067` decision 2 exists to prevent.

Amendment discipline, adopted verbatim from `sob-ADR-0006` decision 4 and
modeled on how `st-ADR-0040` is actually kept - dated in-place amendments
rather than successor records. Adding a measurement or a metadata key to an
existing event is an amendment and is fine. Renaming or removing one,
renaming an event, or changing the `:persistence` driver atom is breaking
and needs a new ADR. A bridge that needs data these events lack gets a new
field here; it never reaches into this package.

### 9. Emission is unconditional: no configuration knob and no sampling knob

Adopted from `sob-ADR-0006` decision 8, on the same grounds and one of this
package's own. `:telemetry.execute/3` on an event with no handlers is a
lookup and a return, so nobody listening already costs nothing; and every
option this package carries is a seam a host must state explicitly
(ADR-0002), which a switch that only makes a cheap thing cheaper is not.

Upstream's `trace: true` gate has no counterpart because nothing in the
`[:statifier_persistence, ...]` family scales with microstep count: the
step, lock, identity, lifecycle, effect and child events are per step or
rarer, and the adapter events are per storage call, which is a small
constant per step. The decision-2 family's nine `:trace` events keep
upstream's gate, because they are upstream's events and it rides the
position (`st-ADR-0060`).

## Consequences

- A host gets, for the first time, a durable run that is visible at all: a
  chart stepped through this package produces the same macrostep spans as
  one hosted in a `Statifier.Session`, distinguished only by
  `statifier.driver: :persistence`. That closes the gap `st-ADR-0067`
  opened this whole line of work to close, and it closes it for
  `statifier_oban` too - its jobs drive this stepper and inherit these
  emissions, which is why `st-ADR-0067`'s Consequences assign that package
  nothing new.
- A host also gets the two numbers that say whether the durable design is
  working and that nothing else can answer: how long the serialized unit
  actually takes, split from the interpreter time inside it, and how often
  the identity guard refuses. A guard refusal is a deploy-drift alarm - a
  chart revision changed under a live run - and today it is a return value
  a host may not even log.
- `StatifierPersistence.Telemetry` becomes public API. Fourteen event
  names, their measurements and their metadata keys are as public as a
  function signature and frozen under decision 8, as is the
  `:persistence` atom. That is a real cost and it is the cost of a bridge
  that attaches without hand-copying a list.
- This package gains a direct `:telemetry` dependency. It is already in
  every dependent's tree through `statifier`, so no host's lock file grows.
- The bridge stays a translator, enforceably. Every field it needs is on an
  event, so "it never reads a blob, a run record, or `Run.Linkage`" is a
  checkable rule rather than an aspiration, and a gap is fixed by an
  amendment here.
- The two departures from `sob-ADR-0006` (decisions 4 and 5) mean the
  family does not have one uniform sibling shape, and a reader comparing
  the two packages has to know why. That is the intended reading of that
  record's own invitation, and `docs/telemetry.md` states both departures
  where a reader of this package will hit them. The precedents that *do*
  bind - the per-package prefix, the `events/0` shape, the
  measurements-are-numbers split, the amendment discipline, and the
  no-knob rule - are adopted unchanged.
- Implementation is a follow-up, not this record. This ADR and
  `docs/telemetry.md` are a specification against which the emit sites -
  `Runs.create/4`, `Runs.step/5`, `Runs.fail/4`, `Runs.cancel/3`,
  `Runs.cascade_cancel/3`, `serialized/4`, `persist_tail/6`, every
  `Storage` facade function, and `Driver`'s `start_child`,
  `answer_parent/3` and turn loop - are written. Filing that work, and
  filing the `opentelemetry_statifier` sibling `setup` call that consumes
  it, are the two named follow-ups.
- What would reopen this record: the deferral in decision 6 firing on its
  stated trigger; a consumer needing an interval this package owns that
  decision 5's single pair does not bracket; or the bridge finding a field
  it needs that no event carries, which decision 8's amendment path
  handles without a new record unless the fix is a rename.
- Rejected alternative: emitting nothing here and letting the bridge derive
  the storage picture from the decision-2 family plus `opentelemetry_ecto`.
  Between them they would show the interpreter call and the SQL, which is
  most of the wall time - but they cannot show the lock wait, cannot
  distinguish a refused step from a step that never arrived, cannot see the
  in-memory adapter at all, and would require the bridge to infer this
  package's phase boundaries from query shapes. `st-ADR-0062` decision 4
  forbids that inference independently of whether it would have worked.
- Rejected alternative: a `[:statifier, :step, ...]` family instead of
  calling `Statifier.Telemetry`. `st-ADR-0067` decision 1 already weighed
  and rejected it for the whole family; restating it here would be this
  package relitigating a contract it defers to.

## Amendment (2026-09-06, sp-8wv): the fan-out settlement gets three events of its own, and `:answered` reports the invocation rather than the door

Decision 5's seams were written before Tier A's fan-out existed. The
settlement section that ADR-0008's sp-3n2 amendment added -
`StatifierPersistence.Driver`'s `decide/4`, `record_and_settle/5` and
`settle/3`, all inside the parent's own exclusion - emits nothing, and a
read-only run of a hybrid fan-out under the bridge (an earlier
scout pass) found three specific holes:

- **Every recorded answer but one is invisible.** A settlement writes the
  finishing child's answer to that child's run record and then asks
  whether every index is terminal. Nine of ten answers in a ten-wide
  fan-out are written and never reach a door, so nothing reported them.
- **The decision itself is invisible.** `:not_yet` is the ordinary answer,
  and an invocation that never settles is indistinguishable from one that
  never started: the counts the decision was made from - how many indexes
  completed, failed, were cancelled, or have no run at all - exist only
  inside `settle/3`.
- **`[:statifier_persistence, :child, :answered]` reported the door, not
  the outcome.** A fan-out answers its parent through
  `done_invocation/5` whatever happened, because st-ADR-0068's failure
  shape is inside each entry rather than around the list. So a
  `first_error` settlement whose second index failed reported
  `outcome: :done`, which is the one thing a consumer counts this event to
  learn.

This amendment is additive under decision 8: two new names and three new
metadata keys, no rename and no removal. It is this package's half of the
operator's ruling of 2026-09-06; nothing about the trace
wire format changes, because these are `:telemetry` events.

**1. `[:statifier_persistence, :child, :recorded]`, once per recorded
answer.** Metadata `parent_run_id`, `child_run_id`, `invoke_id`,
`child_index`, `outcome` (`:done` or `:failed`); measurement
`system_time`. Emitted from `record_and_settle/5` after the write and
inside the parent's exclusion, so it cannot report an answer the
settlement that follows will not read.

**2. `[:statifier_persistence, :child, :settled]`, once per settlement
decision.** Metadata `parent_run_id`, `invoke_id`, `policy`, `decision`
(`:answer` or `:not_yet`); measurements `system_time`, `child_count`,
`completed`, `failed`, `cancelled`, `unstarted`. Emitted from `settle/3`
*after* the decision, so the tallies include the cancels a `first_error`
sweep had just written. A read that fails before reaching a decision emits
nothing: there is no decision to report.

The four tallies are measurements because they are always numbers, under
the measurements-are-numbers split this record's Consequences adopts from
`sob-ADR-0006` unchanged. They partition `child_count` only once every
index has a run of its own; `unstarted` is the indexes with none, which is
what tells a fan-out still starting from one that is stuck.

**3. `:answered`'s `outcome` is the invocation's aggregate for a fan-out,
and it carries `child_count` and `failed_count`.** The aggregate is
`:failed` when any index's entry failed and `:done` otherwise, read off
the dense list the parent is about to be answered with. This changes the
*value* of an existing key rather than the key itself, and it is
deliberately the reading decision 8's amendment discipline permits: the
key still means "how this invocation came out", and it now says so
truthfully. The single-child path is unchanged and reports the door, with
`child_count` and `failed_count` `nil` - one child is not an invocation
with a width, and the two `nil`s say so rather than defaulting to `1` and
`0`.

`child_count` and `failed_count` are metadata rather than measurements,
which is the one place that same measurements-are-numbers split does not
decide the question: a key that is `nil` on a whole class of emissions
cannot be a measurement, and both are dimensions a consumer groups by
rather than quantities it averages. This record already carries one
number as metadata for that reason - `child_index` on
`[:statifier_persistence, :child, :started]` - so the reading is not new
here.

**4. `[:statifier_persistence, :run, :step, :stop]` gains `invoke_id` and
`child_count`.** Both `nil` on every ordinary drive, and set by
`StatifierPersistence.Driver` beside `entry: :answer_parent`. The step
span that carries a whole fan-out's assembled answer through the parent's
door was previously indistinguishable from any other invocation answer,
and `entry` alone cannot separate them. They ride as metadata for the same
reason clause 3 above gives: they are dimensions of the span, not
quantities it measured. They are `StatifierPersistence.Runs` options this
package sets on its own behalf, never a host's - the same posture as
`entry:`.

**Consequences of this amendment.**

- Decision 8's frozen list grows from fourteen event names to **sixteen**.
  The Consequences section above and `docs/adr/README.md`'s index row
  still say fourteen; this clause is the correction, by addition, since an
  accepted record's text is amended and not rewritten.
- A bridge reassembles a fan-out from `(parent_run_id, invoke_id)` across
  `:started`, `:recorded`, `:settled` and `:answered`, with nothing read
  out of `Run.Linkage` and no interval invented for an invocation that
  does not have one. `docs/telemetry.md`'s bridge section states that.
- Cardinality is unchanged in kind: `child_index`, `policy` and `decision`
  are bounded by the chart or by a closed vocabulary, and the new counts
  are measurements. Nothing host-opaque travels - decision 7 holds, and in
  particular no entry's `donedata` is on any of these events. The
  aggregate outcome is computed *from* the entries and only the verdict
  and the failure count leave.
- What would reopen this: a settlement seam that is genuinely an interval
  somebody owns (a single-node fan-out driver), which would want a
  `:start`/`:stop` pair rather than the point-in-time `:settled` this
  clause adds.

## Note (2026-09-06, sp-74k): the count correction reaches decision 3's inventory line too

The sp-8wv amendment above corrects decision 8's frozen list from fourteen
event names to **sixteen**, and names two places still reading the old
count: "the Consequences section above and `docs/adr/README.md`'s index
row". The index row has since been corrected in place (sp-74k, under the
operator's standing word that an index-row count correction is an
in-place edit rather than an amendment).

One site the amendment did not name is decision 3's inventory heading, the
line reading "**Fourteen events**, listed with their measurements and
metadata in `docs/telemetry.md`". It is **sixteen** as of this Note, by
addition, for the same reason the amendment gives: an accepted record's
text is amended and not rewritten. The four things that inventory covers,
and the numbered list beneath it, are unchanged.

The count is checkable against the code: `@events` in
`lib/statifier_persistence/telemetry.ex` holds sixteen names, and
`StatifierPersistence.Telemetry.events/0` returns them. The two the
amendment added are `[:statifier_persistence, :child, :recorded]` and
`[:statifier_persistence, :child, :settled]`.

No decision moves. Nothing in decision 8's freeze changes: this Note
corrects prose that trailed a correction already taken.

## Note (2026-09-13, sp-478): `run` in this record is the noun now called `execution`

Pure addition: nothing above is edited, and the event contract this record
decides is read at the dates its sections were decided.

**Read `run` as `execution` from 0.12.0.** Every `run` in this file - the
durable noun, the module and function names, the ids and the column names it
cites - names the record this package now calls an `execution`, with one
exception named below. `StatifierPersistence.Execution` and
`StatifierPersistence.Executions` are the modules
(`lib/statifier_persistence/execution.ex:1`,
`lib/statifier_persistence/executions.ex:1`), the error atom is
`:execution_not_found` (`lib/statifier_persistence/executions.ex:710`), and
the telemetry family is `[:statifier_persistence, :execution, ...]` carrying
`execution_id` metadata (`lib/statifier_persistence/telemetry.ex:60-62`) -
each read at `71537dc`. The table, column and index half is V06
(`lib/statifier_persistence/ecto/migrations/v06.ex:2`, read at `71537dc`),
and the whole rename ships in 0.12.0. **ADR-0011 governs the noun**
(`docs/adr/0011-execution-is-the-durable-noun.md`).

**The exception is the donedata key.** The reserved key spelled
`statifier_persistence:run_status` in this record keeps that spelling as a
key that is still *read*: 0.12.0 reads both it and
`statifier_persistence:execution_status`, the new key winning where both are
present and the old one logging one deprecation line, and 0.13.0 reads only
the new one (ADR-0011 decision 4; `@execution_status_key`
`lib/statifier_persistence/executions.ex:1686` and
`@legacy_execution_status_key` `:1694`, read at `71537dc`). So a `run` that
names that key is the one `run` in this file that is not simply read as
`execution` for one release.

This record's decisions are unchanged by the rename - only the word is - and
the file name keeps `run` because a file name is a cite target.

The event names this record freezes move with the noun and with no dual emit
(ADR-0011 decision 5): `[:statifier_persistence, :run, ...]` reads
`[:statifier_persistence, :execution, ...]` and the `run_id` metadata key
reads `execution_id`, both at `lib/statifier_persistence/telemetry.ex:60-62`,
read at `71537dc`. Decision 8's freeze is unchanged: the count and the
structure of the table are what it fixes, not the spelling of the noun.

## Amendment (2026-09-23, sp-7a9): a migration is this package's verdict on an execution, and it gets one event of its own

Status of this amendment: accepted (2026-09-23, sp-7a9). The record above
stays accepted; this amendment is proposed until the operator accepts it.

ADR-0013 (`docs/adr/0013-the-migration-plan.md`, proposed) decides that
`StatifierPersistence.Executions.migrate/4` re-pins an execution onto
another chart, and its decision 5 decides that a successful migration emits
one event, `[:statifier_persistence, :execution, :migrated]`, with
`system_time` as its measurement and `execution_id`, `from_content_hash`,
`to_content_hash` and `dropped` as its metadata. Decision 3 above lists this
family's events and says they cover "exactly four things and nothing else",
and none of the four names a migration. This amendment adds the event to the
catalogue. It is additive under decision 8: one new name, no rename and no
removal.

**1. The event belongs to decision 3's third thing, this package's own
verdicts on an execution.** A migration is a verdict this package reaches
about an execution - moved onto another chart - that no interpreter reaches:
the migration delivers no event and takes no transition (ADR-0013 decision
5), so family one reports nothing about it, which is the same reason decision
3 gives for reporting `fail/4` and `cancel/3` here. The four things are
still four; the third now includes a migration. The event is a
point-in-time event under decision 5, not a pair: a migration is not a step,
it opens no step span, and ADR-0010's door vocabulary, which is also the
`entry` vocabulary on the step seam, does not grow (ADR-0013 decisions 4 and
5). It is emitted once per successful `migrate/4`, after the execution's
serialization section returns; a refused or parked migration emits nothing,
and whether it should is one of the things ADR-0013 leaves undecided.

**2. Two content hashes under two names, reconciled with decision 4.**
Decision 4 says `content_hash` rides where a chart identity is in hand. A
migration has two in hand, and a single `content_hash` key would have to
choose one and drop the other. The event follows the precedent this family
already has for an event that holds two identities: the identity guard's
refusal names its two hashes `stored_content_hash` and
`supplied_content_hash` rather than choosing
(`lib/statifier_persistence/telemetry.ex`, `identity_refused/1`, read at
`8692aac`). So decision 4 is read as: one identity in hand rides as
`content_hash`, and two ride under a name each, here `from_content_hash` (the
chart the execution was pinned to) and `to_content_hash` (the chart it is
pinned to now). `session_id` is not on the event: decision 4 lets it ride
only where a position has been decoded, and ADR-0013 decision 5 names the
four keys above; adding it later is an amendment under decision 8.

Decision 7 holds. `dropped` is a list of state ids the plan dropped that
were in the execution's configuration: author-written ids of a chart,
bounded by the chart, and nothing from the datamodel, the position blob or
the metadata map.

**3. The count is seventeen.** Decision 8's frozen list grows from sixteen
event names to **seventeen**. The sixteen stated in decision 3's inventory
line (as the sp-74k Note above reads it), in the sp-8wv amendment's
consequences and in `docs/adr/README.md`'s index row are corrected by this
addition; this amendment edits none of them in place. The count is
checkable against the code: `@events` in
`lib/statifier_persistence/telemetry.ex` holds sixteen names at `8692aac`,
and the change that carries this amendment adds the seventeenth,
`@execution_migrated`, with its emitter `execution_migrated/1`;
`StatifierPersistence.Telemetry.events/0` returns all seventeen, and
`docs/telemetry.md`'s execution lifecycle table carries the new row.

No other decision moves.

## Amendment (2026-09-23, sp-6neq): `:answered` says what the parent's door answered

Status of this amendment: accepted (2026-09-23, sp-6neq). The record above
stays accepted; this amendment is proposed until the operator accepts it.

ADR-0014 (`docs/adr/0014-the-needs-migration-status.md`, accepted) decides
that a delivery to a `:needs_migration` execution is refused whole and that
delivering it again is the host's (its decision 2). Its Consequences name
one delivery path that does not come back to a host: a durable child's
automatic answer to a parked parent, because `Driver`'s automatic answer
returns the child's own result whatever the parent's door answered
(`lib/statifier_persistence/driver.ex`, `maybe_answer_parent/3`, read at
`fb1662f`). The one event that fires at that point,
`[:statifier_persistence, :child, :answered]`, is emitted after the door
returns and says nothing about what it returned
(`lib/statifier_persistence/driver.ex`, `report_answered/3`, read at
`fb1662f`), so a refused answer is reported exactly as a delivered one. The
step seam's stop does report the refusal as `reason: :needs_migration`
(`lib/statifier_persistence/executions.ex`, `stop_shape/1`, read at
`fb1662f`), but on the parent's `execution_id` and without the child's,
which is the id a redelivery through `Driver.answer_parent/3` needs.

This amendment is additive under decision 8: one new metadata key on an
existing event, no rename and no removal, and no new event name.

**1. `:answered` gains `delivery`, what the parent's door answered.** A
closed vocabulary of four: `:delivered` for `{:ok, execution,
machine_state}`, `:discarded` for `{:discarded, execution}`,
`:needs_migration` for `{:error, {:needs_migration, execution}}`, and
`:error` for any other error. It is set on both emit sites, the single
child's and a fan-out settlement's, because both answer through the same
door. The event still fires once per answer, after the door returns, and
`outcome` keeps its meaning: how the child or the invocation came out, not
what the parent did with it.

**2. The parked parent is named apart from every other error.** It is the
one refusal ADR-0014 decision 2 tells a host to deliver again, and a
handler has to be able to recognise it without reading an error term.
`:discarded` is named apart for the opposite reason: a discard is ADR-0007
decision 3's mechanism working, not something to retry.

**3. Decision 7 holds.** Neither the parent's execution nor the error's own
term travels; `delivery` is an atom from the vocabulary above, bounded, and
fit to be a metric dimension. The answer itself - the donedata - is still
not on the event. A host that delivers again holds the answer where it
drove the child: the event is emitted on that process, before the child's
drive returns.

**4. The change is not queuing.** Nothing in this package holds the refused
answer or delivers it later; ADR-0014 decision 8 leaves that undecided and
this amendment does not decide it. `Driver`'s automatic answer still
returns the child's own result.

No other decision moves, and decision 8's count of event names does not
change.

## Note (2026-09-23, sp-o2ev): the sp-6neq Amendment is accepted

The operator accepted the 2026-09-23 sp-6neq Amendment on 2026-09-23,
after the code that implements it shipped in statifier_persistence 0.15.0
(tag `v0.15.0`, `ae9c855`). That Amendment's own status line flips in
place from proposed to accepted, and the record above stays accepted. Its
"this amendment is proposed until the operator accepts it" is met here
and stays as written. The 2026-09-23 sp-7a9 Amendment is flipped by the
Note below. Every cite below was read on `main` at `ae9c855`.

What was re-read before the flip:

- **Decisions 1 and 2.** `delivery` maps the door's answer onto the four
  atoms, with the parked parent named apart
  (`lib/statifier_persistence/driver.ex`, `delivery/1`). Both emit sites
  set it after the door returns: the single child's
  (`report_answered/4`) and a fan-out settlement's
  (`report_settled_answer/4`). `outcome` keeps its meaning.
  `lib/statifier_persistence/telemetry.ex`'s table lists the key on
  `[:statifier_persistence, :child, :answered]`, and no event name was
  added.
- **Decision 3.** The event carries an atom and no execution, error term
  or donedata. It is emitted in the caller's process before the caller's
  call returns. A redelivery through `Driver.answer_parent/3` needs the
  child's own answer, which that caller holds.
- **Decision 4.** Nothing in the package queues a refused answer.
  `maybe_answer_parent/3` still returns the child's own result.

Decision 3's wording is looser than the code in two places. Residue
sp-4zls tracks both, and they are recorded here without a change to the
Amendment. First, an outside fail answers through
`Driver.resolve_and_answer_parent/3` from `Executions.fail/4`, a path with
no drive of the child. Second, a fan-out child's own answer is also stored
on the child execution (`driver.ex`, `record_outcome/3`), while a single
child's is not stored (`lib/statifier_persistence/execution.ex`, whose
stored record carries no donedata). Neither makes the decision false: in
both cases the event is emitted before the caller's call returns, and the
caller holds the answer a redelivery needs.

## Note (2026-09-23, sp-o2ev): the sp-7a9 Amendment is accepted

The operator accepted the 2026-09-23 sp-7a9 Amendment on 2026-09-23. The
code that implements it shipped in statifier_persistence 0.14.0 and is on
`main` at `v0.15.0` (`ae9c855`). That Amendment's own status line flips in
place from proposed to accepted. Its "this amendment is proposed until the
operator accepts it" is met here and stays as written. Every cite below was
read on `main` at `ae9c855`, including the commits since `v0.14.0` on
`telemetry.ex`, `executions.ex` and `docs/telemetry.md`.

What was re-read before the flip:

- **The event and its shape.** `@execution_migrated` and its emitter
  `execution_migrated/1` are in `lib/statifier_persistence/telemetry.ex`,
  with `system_time` as the measurement and `execution_id`,
  `from_content_hash`, `to_content_hash` and `dropped` as the metadata.
  `session_id` is not on it. The two-hash precedent is `identity_refused/1`
  (`stored_content_hash`, `supplied_content_hash`).
- **When it fires.** It fires once per successful `migrate/4`, after the
  serialization section returns (`executions.ex`, `migrated/2`), and a
  refused or parked `migrate/4` emits nothing. `migrate/4` opens no step
  span, and `t:StatifierPersistence.Executions.entry/0` has no migration
  door.
- **The count is seventeen.** `@events` lists seventeen names, and
  `events/0` returns them. The sp-6neq Amendment below added a key, not a
  name. `docs/telemetry.md`'s execution lifecycle table carries the row.

Two sentences are superseded by later dated records on main and stay as
written. First, "It is emitted once per successful `migrate/4`" still holds
for `migrate/4`, and ADR-0015 decision 5
(`docs/adr/0015-the-tree-migration.md`, accepted in this change) adds
`migrate_tree/4` as a second
emitter: once per re-pinned node, with the same keys (`executions.ex`,
`tree_migrated/1`). `docs/telemetry.md` names both emitters. Second, the
Amendment's opening calls ADR-0013 proposed, and ADR-0013's status line
now reads accepted.

## Amendment (2026-09-23): a raising drive closes the step span with an exception event

Status of this amendment: accepted (2026-09-23). The record above stays
accepted; this amendment is proposed until the operator accepts it.

Decision 2 says that both halves of every span this package opens arrive
inside one synchronous call, so there is no open-span entry for the bridge
to leak, and decision 5 says both halves of the step span are emitted inside
one function call. That held only for a drive that returns. The step span's
start was emitted, the serialization strategy's `with_execution/3` ran the
drive, and the stop was emitted after it returned, with nothing between to
catch a raise (`lib/statifier_persistence/executions.ex`, `serialized/5`,
read at `e3dda64`). The host's executor and event builder run inside that
call, so a raising host callback left a start with no second half. The
record was right and the code was wrong. This amendment adds the event that
makes decisions 2 and 5 hold for a raise, a throw and an exit too. It is
additive under decision 8: one new event name, no rename and no removal.

**1. The step span closes with `:exception` in place of `:stop`.**
`[:statifier_persistence, :execution, :step, :exception]` is emitted when
anything inside the drive raises, throws or exits, and the stop is then not
emitted. The raise reaches the caller unchanged, re-raised with its original
stacktrace; nothing is rescued to a return value, so the repository's rule
against rescuing to a default at a leaf is untouched. The event is emitted
from `serialized/5` in the change that carries this amendment.

**2. The keys are `:telemetry.span/3`'s.** That function closes a span on a
raise with an `:exception` event carrying `duration` and `monotonic_time` as
measurements and the start's metadata plus `kind`, `reason` and
`stacktrace` (`deps/telemetry/src/telemetry.erl`, `span/3`, telemetry
1.4.2 as locked). This event carries the same: `duration` and
`monotonic_time`, and `execution_id`, `entry` and `span_ref` from the
start, plus `kind`, `reason` and `stacktrace`. `span_ref` pairs it with its start as it pairs a
stop. The stop's other keys are not on it: a raise leaves no return value
to read `outcome`, `status` or a decoded `session_id` from, and decision 4
forbids a lookup made to fill a field in.

**3. Decision 7 holds, and `reason` and `stacktrace` are narrowed to keep
it.** An event builder is called with the decoded machine state, which
holds the datamodel, and a raise can carry any value the failing code held:
a failed match on the state raises with the whole state as its reason, and a
function-clause frame carries the call's arguments. So the two fields that
could carry state are narrowed before the event is emitted
(`lib/statifier_persistence/telemetry.ex`, `execution_step_exception/2`, in
this change):

- `reason` is the exception's module for an `:error`, a raw Erlang error
  normalized first, so a failed match reports `MatchError`; for a `:throw`
  or an `:exit` it is the thrown or exit atom, or `:redacted` for any other
  term. The raised value never travels.
- `stacktrace` keeps each frame's module and function, replaces an argument
  list by its arity, and keeps only `:file` and `:line` of the location.

Every other field is the start half's own: `execution_id`, `entry` and
`span_ref`, and `kind` is one of three atoms. The caller's re-raise is
untouched and sees the original reason and stacktrace. `reason` is
therefore a bounded name, not the raised term `:telemetry.span/3` would
carry; the key names are unchanged.

**4. The count is eighteen.** Decision 8's frozen list grows from seventeen
event names to **eighteen**. `@events` in
`lib/statifier_persistence/telemetry.ex` holds seventeen names at
`e3dda64`, and this change adds the eighteenth,
`@execution_step_exception`, after the stop, with its emitter
`execution_step_exception/2`. `StatifierPersistence.Telemetry.events/0`
returns all eighteen, and `docs/telemetry.md`'s step seam table carries the
new row. The earlier counts in this record and in `docs/adr/README.md`'s
index row are corrected by this addition; this amendment edits none of them
in place.

Decision 5's "a `:start` / `:stop` pair" reads as a start and exactly one of
a stop or an exception. There is still one span, and nothing else in family
two becomes a span.

A handler that matches the names `events/0` returns exhaustively needs a
clause for the new one, and a bridge that checks a hand-copied list
against `events/0` needs the name added.

Not decided here: the family-one macrostep span this package opens around
`Interpreter.handle_event/2` has the same shape, a start with nothing to
close it if the advance raises (`lib/statifier_persistence/executions.ex`,
`open_macrostep/4` and `close_macrostep/6`, read at `e3dda64`). Its event
names are statifier-ex's under `st-ADR-0067`, and it is unchanged.

No other decision moves.

## Amendment (2026-09-23): an unpark gets one event of its own, and its wait is the lock event

Status of this amendment: accepted (2026-09-23). The record above stays
accepted; this amendment is proposed until the operator accepts it.

ADR-0014 (`docs/adr/0014-the-needs-migration-status.md`, accepted) leaves
open, in its decision 8, whether the park and the unpark emit telemetry of
their own, and its Amendment of this date decides the unpark's: one event,
`[:statifier_persistence, :execution, :unparked]`, with `system_time` as
its measurement and `execution_id` and `content_hash` as its metadata,
emitted once per `StatifierPersistence.Executions.unpark/3` that writes a
`:needs_migration` execution back to `:active`, and the existing
`[:statifier_persistence, :execution, :lock]` for the unpark's wait. It
leaves the park's event undecided. This amendment adds the event to the
catalogue. It is additive under decision 8: one new name, no rename and no
removal.

**1. The event belongs to decision 3's third thing, this package's own
verdicts on an execution.** An unpark is a host decision about an
execution that no interpreter runs on, which is the reason decision 3
gives for reporting `fail/4` and `cancel/3` here. The four things are
still four; the third now includes an unpark. The event is a
point-in-time event under decision 5, not a pair: an unpark is not a step,
it opens no step span, and the step seam's `entry` vocabulary does not
grow.

**2. The lock event gains an emit site outside the step span.** Decision
3's first thing names "the per-run exclusion wait ahead of" the durable
step, `run` read as `execution` under the 2026-09-13 Note above.
`unpark/3` takes the same exclusion, and reports its wait
through the same event with the same keys (`execution_id`, `strategy`,
`outcome`, `reason`) and the same `duration`, the wait and not the held
time. Nothing brackets it: there is no step span around an unpark for the
lock event to sit inside. `migrate/4` and `migrate_tree/4` also take the
exclusion through the strategy directly and still emit no lock event
(`lib/statifier_persistence/executions.ex`, `migrate/4` and
`with_exclusions/4`, read at `a6e393f`); this amendment does not change
them.

**3. Decision 4 and decision 7 hold.** One chart identity is in hand, the
chart the execution was parked on and goes on under, and it rides as
`content_hash`. No position is decoded, so `session_id` is not on the
event. Nothing from the datamodel, the blobs or the metadata map travels.

**4. The count is nineteen.** Decision 8's frozen list grows from eighteen
event names to **nineteen**. `@events` in
`lib/statifier_persistence/telemetry.ex` holds eighteen names at
`a6e393f`, and this change adds the nineteenth, `@execution_unparked`,
after `@execution_migrated`, with its emitter `execution_unparked/1`.
`StatifierPersistence.Telemetry.events/0` returns all nineteen, and
`docs/telemetry.md`'s execution lifecycle table carries the new row. The
earlier counts in this record and in `docs/adr/README.md`'s index row are
corrected by this addition; this amendment edits none of them in place.

A handler that matches the names `events/0` returns exhaustively needs a
clause for the new one, and a bridge that checks a hand-copied list
against `events/0` needs the name added.

No other decision moves.

## Amendment (2026-09-23, sp-q0pp): `delivery` names the two ways an answer never reaches the parent's door

Status of this amendment: proposed (2026-09-23, sp-q0pp). The record above
stays accepted; this amendment is proposed until the operator accepts it.

The sp-6neq Amendment gave `[:statifier_persistence, :child, :answered]` a
`delivery` key saying what the parent's door answered, so that a refused
automatic answer reaches the host. One step before the door was still
silent. Before the automatic answer can call the parent's door it fetches
the parent's own record and resolves the parent's chart through the
driver's `chart_resolver:`, and a failure at either step was dropped with
nothing emitted and nothing returned: the code called it "silently a
no-op" (`lib/statifier_persistence/driver.ex`, `resolve_and_answer/4`, read
at `a6e393f`). The child's own drive returns its own result whatever
happens there (`maybe_answer_parent/3`, read at `a6e393f`), and the outside
fail path's `Driver.resolve_and_answer_parent/3` returns `:ok` by its
public `@spec` (read at `a6e393f`). So an answer that went nowhere looked,
to the host, the same as one that was delivered: the lost answer the
sp-6neq Amendment closed for a parked parent, arriving by another route.

This amendment is additive under decision 8: two new values of an existing
metadata key, no new key, no rename and no removal, and no new event name.

**1. `delivery` gains `:parent_unfetched` and `:parent_chart_unresolved`.**
`:parent_unfetched` is emitted when the parent's own record does not fetch;
`:parent_chart_unresolved` when it fetched but the resolver did not return
its chart. They are named apart because a host acts on them differently:
the first is a storage fact about the parent's execution, the second is a
chart the host's resolver does not hold for that execution's
`content_hash`. The vocabulary of the sp-6neq Amendment's decision 1 reads
as six values, and its framing widens to match: `delivery` says what
became of the answer - what the door answered, or which of these two
reasons kept it from the door.

**2. The event fires where the answer stopped, on the same process.**
It is emitted from the step that failed (`resolve_and_answer/4`, in this
change), which is reached by the automatic answer and by
`Driver.resolve_and_answer_parent/3`. The linkage has already been read at
that point, so `child_execution_id`, `parent_execution_id`, `invoke_id` and
`child_count` are the same values a delivered answer reports. This widens
the sp-6neq Amendment's decision 1, under which the event fires once per
answer after the parent's door returns: it now also fires when no door ran,
and then only with one of these two `delivery` values.

**3. `outcome` is the child's own and `failed_count` is `nil`.** No door
ran and, for a fan-out, no settlement was entered, so there is no
assembled answer to take the invocation's aggregate from or to count.
`outcome` is the child's `:done` or `:failed`, which is the same value it
has on the single-child path. For a fan-out this departs from the sp-8wv
Amendment's decision 3 on two values: there `outcome` is the invocation's
aggregate and `failed_count` an integer, and here they are the child's own
outcome and `nil`. A handler tells the two apart by `delivery`: the
sp-8wv reading holds on every value except `:parent_unfetched` and
`:parent_chart_unresolved`.

**4. Decision 7 holds.** Neither the fetch's error term nor anything the
resolver returned travels; `delivery` stays an atom from a closed
vocabulary, fit to be a metric dimension. The donedata is still not on the
event.

**5. No return value changes.** `Driver.resolve_and_answer_parent/3` still
returns `:ok` and the automatic answer still returns the child's own
result. Delivering the answer once the parent can be reached is the
host's, through `Driver.answer_parent/3` with a driver over the parent's
chart; nothing in this package holds the answer, as the sp-6neq
Amendment's decision 4 already says.

Not decided here: a failed read of the child's own record, which is where
the linkage comes from, is still `:ok` from
`Driver.resolve_and_answer_parent/3` with nothing emitted, because there is
no linkage to name a parent from. The settlement section's own storage
errors on a fan-out are likewise unchanged.

Two earlier decisions move, each only on these two `delivery` values: the
sp-6neq Amendment's decision 1 (decision 2 above) and the sp-8wv
Amendment's decision 3 (decision 3 above). Decision 8's count of event
names does not change.

## Note (2026-09-24, sp-2wwq): the step-exception Amendment is accepted

The 2026-09-23 Amendment "a raising drive closes the step span with an
exception event" is accepted on 2026-09-24, under the operator's standing
grant to flip a record whose code has shipped. The code that implements it
shipped in statifier_persistence 0.15.1 (tag `v0.15.1`, `3e25271`). That
Amendment's own status line flips in place from proposed to accepted, and
the record above stays accepted. Its "this amendment is proposed until the
operator accepts it" is met here and stays as written. Every cite below was
read at `3e25271`, the tag, and again on `main` at `183a849`, where none
of them changed.

What was re-read before the flip:

- **Decision 1.** `serialized/5` in
  `lib/statifier_persistence/executions.ex` catches a raise, throw or exit
  from the strategy's `with_execution/3`, emits
  `[:statifier_persistence, :execution, :step, :exception]` in place of the
  stop, and re-raises with `:erlang.raise/3` and the original stacktrace.
- **Decision 2.** The keys match `:telemetry.span/3`'s exception close in
  telemetry 1.4.2, the version `mix.lock` resolves: `duration` and
  `monotonic_time` as measurements, and `execution_id`, `entry` and
  `span_ref` from the start plus `kind`, `reason` and `stacktrace`
  (`lib/statifier_persistence/telemetry.ex`, `execution_step_exception/2`).
- **Decision 3.** `reason` is the normalized exception module for an
  `:error`, the atom for a throw or an exit, and `:redacted` otherwise
  (`telemetry.ex`, `narrow_reason/3`); `stacktrace` keeps module,
  function, arity, `:file` and `:line` (`telemetry.ex`,
  `narrow_stacktrace/1`).
- **Decision 4.** `@execution_step_exception` sits after the stop in
  `@events`, and `docs/telemetry.md`'s step seam table carries the row.
- **Not decided.** `open_macrostep/4` and `close_macrostep/6` in
  `executions.ex` are unchanged by it.

One sentence is superseded by a later dated record on `main` and stays as
written. Decision 4's "The count is eighteen" held when this Amendment
landed. The 2026-09-23 Amendment below it, "an unpark gets one event of its
own, and its wait is the lock event", adds a nineteenth name, and `@events`
lists nineteen at `3e25271`.

## Note (2026-09-24, sp-2wwq): the unpark-event Amendment is accepted

The 2026-09-23 Amendment "an unpark gets one event of its own, and its wait
is the lock event" is accepted on 2026-09-24, under the operator's standing
grant to flip a record whose code has shipped. The code that implements it
shipped in statifier_persistence 0.15.1 (tag `v0.15.1`, `3e25271`). That
Amendment's own status line flips in place from proposed to accepted, and
the record above stays accepted. Its "this amendment is proposed until the
operator accepts it" is met here and stays as written. Every cite below was
read at `3e25271`, the tag, and again on `main` at `183a849`, where none
of them changed.

What was re-read before the flip:

- **Decision 1.** `Executions.unpark/3` emits
  `[:statifier_persistence, :execution, :unparked]` through
  `Telemetry.execution_unparked/1` and opens no step span
  (`lib/statifier_persistence/executions.ex`, `unparked/1`).
- **Decision 2.** `unpark/3` reports its wait through `emit_lock/5` and
  `unlocked/4`, the helpers `serialized/5` uses. `migrate/4` and
  `with_exclusions/4` call the strategy's `with_execution/3` and emit no
  lock event.
- **Decision 3.** The event's metadata is `execution_id` and
  `content_hash`, with `system_time` as its measurement
  (`lib/statifier_persistence/telemetry.ex`, `execution_unparked/1`).
- **Decision 4.** `@execution_unparked` sits after `@execution_migrated`
  in `@events`, which lists nineteen names, and `docs/telemetry.md`'s
  execution lifecycle table carries the row.

## Amendment (2026-09-24, sp-226): each re-entered `error.communication` gets an event inside the step span

Status of this amendment: proposed (2026-09-24, sp-226). The record above
stays accepted; this amendment is proposed until the operator accepts it.

ADR-0004 decision 4 re-enters an executor failure on an actionable effect
into the chart as `error.communication`, inside the persist tail. That event
is one no host delivered, and until this change nothing outside the tail
could see it whole: `[:statifier_persistence, :effect, :failed]` reports the
effect's kind, the executor, its reason and whether a re-entry happened
(`lib/statifier_persistence/executions.ex`, `report_failure/3`, read at
`fe06c8d`), but not the cause origin and options the re-entry was raised
with (`deliver_reentry/4`, read at `fe06c8d`). A host that event-sources an
execution, folding the events it delivered to rebuild the position,
therefore diverges from the persisted position on that edge. Ruled by the
operator, 2026-09-24: expose each re-entry through one additive event, with
the step's return untouched.

This amendment is additive under decision 8: one new event name, no rename
and no removal.

**1. The event is `[:statifier_persistence, :execution, :step, :reentered]`,
one per delivered re-entry.** It is emitted once the re-entry has been
delivered to the chart, and only then (`report_reentry/3`, called from
`deliver_reentry/4`, in this change). A failure whose re-entry was not
delivered emits none: an observational effect's failure, a failure after a
re-entry reached a final state, and a failure after the macrostep budget ran
out. `[:statifier_persistence, :effect, :failed]` is unchanged and still
fires for every failure.

**2. It is a point-in-time event inside the step span, and decision 5
holds.** Every persist tail runs inside `serialized/5` (`create/4` and
`step/5`, read at `fe06c8d`), so the event is emitted on the calling
process after the step's `:start` and before its `:stop` or `:exception`,
in delivery order. It is not a third half of the span: it carries
`system_time` alone, as decision 5's other point-in-time events do, and a
handler that reads every `[:statifier_persistence, :execution, :step, _]`
name as a span phase must not treat it as one. It carries no `span_ref`; it
pairs with its step by `execution_id` and by arriving between that step's
halves. Adding `span_ref` later is an amendment under decision 8.

**3. The metadata is the three values the re-entry was delivered with, and
decision 4's identity keys.** `name` is `"error.communication"`; `origin`
is the `Statifier.Event.Cause.origin/0` tuple; `opts` is the keyword list,
`[sendid: id]` for a failed `<send>`, delayed or not, and `[]` for
every other effect (`reentry_origin/1`, read at `fe06c8d`). They are the
arguments `Statifier.Interpreter.deliver_internal/5` received beside
`:platform`, unchanged, so a host folding its delivered events and then
these, in order, through that function reaches the persisted position. A
position has been decoded, so `session_id` rides with `execution_id` and
`content_hash`, as on `:effect, :failed`.

**4. Decision 7 holds, and one key is unbounded.** `origin` is indexes into
the chart and is bounded by it. `opts` carries a `<send>`'s `sendid`, which
is the element's own `id` or one the interpreter generated for it: not a
datamodel value, but unbounded, so it takes the status decision 7 gives the
execution id - a value for a fold to replay, never a metric dimension.

**5. The count is twenty.** Decision 8's frozen list grows from nineteen
event names to **twenty**. `@events` in
`lib/statifier_persistence/telemetry.ex` holds nineteen names at `fe06c8d`,
and this change adds the twentieth, `@execution_step_reentered`, after
`@execution_step_exception`, with its emitter `execution_step_reentered/1`.
`docs/telemetry.md`'s step seam table carries the new row. The earlier
counts in this record and in `docs/adr/README.md`'s index row are corrected
by this addition; this amendment edits none of them in place.

A handler that matches the names `events/0` returns exhaustively needs a
clause for the new one, and a bridge that checks a hand-copied list against
`events/0` needs the name added.

No other decision moves.

## Amendment (2026-09-25, sp-qrkx): the step stop says whether the delivered event selected a transition

Status of this amendment: proposed (2026-09-25, sp-qrkx). The record above
stays accepted; this amendment is proposed until the operator accepts it.

A caller of `step/5` cannot tell a delivery that moved the chart from one
that selected no transition at all unless the position was created with
`trace: true`: the engine's selection trace reaches only the executor, and
only when tracing is on. A router that wants to record such a delivery as
unmatched has nothing to read. Ruled by the operator, 2026-09-24: `step/5`'s
return stays as it is; the engine stamps the external round's selection on
the `MachineState` it already returns, and this package adds a key to the
step stop.

This amendment is additive under decision 8: one new metadata key on an
existing event, no rename and no removal. The event count does not move.

**1. The key is `selection` on `[:statifier_persistence, :execution, :step,
:stop]`.** Its value is `:selected`, `:none` or `nil`, read off the returned
position's `last_selection` (`selection/1`, called from
`step_stop_fields/5`, in this change). statifier 2.9.0 adds that field and
writes it in `Statifier.Interpreter.handle_event/2` on every external
round, whether or not tracing is on (`handle_event/2`, statifier 2.9.0), so
the dependency floor moves to `~> 2.9` in this change.

**2. It is set wherever a delivered event ran a round.** On an `:ok` stop
whose `entry` is `:step`, `:done_invocation`, `:failed_invocation` or
`:answer_parent`, `selection` is `:selected` or `:none`: each of those doors
delivers its event to `handle_event/2` (`stepped/8`, read at `cfa460c`), and
`:answer_parent` is the parent's own invocation door taken on a child's
behalf (`answer_opts/1` in `lib/statifier_persistence/driver.ex`, read at
`cfa460c`). It is the delivered event's own answer: the
eventless and internal rounds that fold after it do not change it, and
neither does an `error.communication` the persist tail re-enters through
`Statifier.Interpreter.deliver_internal/5` (the field's typedoc,
`Statifier.MachineState`, statifier 2.9.0).

**3. It is `nil` where no event ran a round.** A `:create` stop returns a
position `Statifier.Interpreter.initialize/2` built, which reads `nil`; a
`:fail` or `:cancel` stop returns no position (`fail_tail/3`,
`cancel_tail/2`, read at `cfa460c`); and every `:discarded` or `:error`
stop returns none either (`stop_shape/1`, read at `cfa460c`). A step whose
builder declined, or that reached a terminal position, discards before any
round. The key is `nil` there, explicitly, rather than absent, as decision 4
treats `session_id` where no position was decoded; this amendment's own rule
is that the stop carries `selection` on every return path.

**4. `:none` does not say why.** An event no transition names and one
whose every matching transition's guard was false both read `:none`. That
is the engine's field as statifier 2.9.0 defines it, and this package
passes it through without refinement.

**5. Decision 7 holds.** The value is a closed vocabulary of three atoms and
carries nothing from the datamodel. `step/5`'s return is unchanged: a
caller holding the returned position can read `last_selection` from it
directly, and the key exists for a caller that has only the event.

No other decision moves.
