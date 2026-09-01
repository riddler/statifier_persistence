# ADR-0009: Telemetry for the durable stepper: `:persistence` on the family contract, plus a storage-phase family of this package's own

Status: proposed (2026-09-01, sp-i21)

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
