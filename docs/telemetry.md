# Telemetry and the OpenTelemetry bridge half

This note is the design record for what `statifier_persistence` emits and
what it deliberately leaves to others. It was written as a specification
ahead of the code; the family-two emit sites landed in sp-m0i and the
family-one ones in sp-t01, so both tables below now describe what this
package emits rather than what it promises to. Nothing in the contract
changed on the way in -
`docs/adr/0009-telemetry-events-for-the-durable-stepper.md` froze it, and
decision 8's amendment discipline is how it moves.

One row is specification still, and the table says so where it sits:
`[:statifier, :session, :unroutable]` has no emit site, because no seam in
this package can currently produce the case it names.

Four records govern and are not restated here:

- `st-ADR-0062` and `statifier-ex`'s `docs/opentelemetry.md` - the family's
  span topology and the ruling that the OpenTelemetry bridge is one
  separate package, `opentelemetry_statifier`, consuming public
  `:telemetry` events only. Its "What lands where" table gives this
  repository two rows, and both are this note's mandate.
- `st-ADR-0067` - one telemetry contract across stepping drivers. Its
  decision 2 puts the emitters in `Statifier.Telemetry`; decision 3
  tabulates what a process-less driver emits; decision 4 adds the `driver`
  metadata key; decision 6 says the storage phases are this package's own
  surface, under `[:statifier_persistence, ...]`.
- `st-ADR-0040` (as amended by `st-ADR-0067`) and `Statifier.Telemetry` -
  the family's event conventions, adopted here in full except where this
  note records a deliberate departure.
- `sob-ADR-0006` and `statifier_oban`'s `docs/telemetry.md` - the sibling
  that went first, whose precedents this note adopts and, twice,
  deliberately departs from.

## Two families, and why this package has two

Every other sibling in the family emits one event family of its own. This
package emits that, and it also emits the *interpreter's* family, because
it is a stepping driver.

**Family one: `[:statifier, :session, ...]`, emitted through
`Statifier.Telemetry` with `driver: :persistence`.** A run stepped here
produces the same 27-name contract a run hosted in a `Statifier.Session`
does - the same macrostep spans, the same effect events, the same
counters - because this package calls the same functions `session.ex`
calls rather than reimplementing a documented table. This is the whole
point of `st-ADR-0067`: a backend user should not have to know that a
durably-stepped macrostep is a different kind of thing, because it is not.
The one difference is the `statifier.driver` attribute.

**Family two: `[:statifier_persistence, ...]`, this package's own.**
Everything about how a position got into memory and back out: the
serialized unit, the lock, the adapter calls, the identity guard, the run
record's lifecycle, the executor seam's failures, and the durable-subchart
seam. `st-ADR-0067` decision 6 draws that line and names this namespace.

The two nest. A durable macrostep span appears *inside* the step span this
package opens around it, because the bridge parents it from its own
pid-keyed span table (`ots-ADR-0004` decision 4) rather than from the
process's ambient OTel context, which it never reads; both are emitted in
the same process during the same synchronous call, which is what puts them
in one row's reach.

## Family one: what this package emits as a driver

Applicability is `st-ADR-0067` decision 3's table. What that means here,
concretely, at the emit sites:

| Event | Emitted by this package? | Where |
|---|---|---|
| `[:statifier, :session, :init]` | yes, exactly once per logical run | `Runs.create/4`, around `Interpreter.initialize/2`, `resumed: false`, `invoked_by: nil`. **Never on a load** - every `Runs.step/5` is a rehydration, and an `:init` per load would fire thousands of times per run |
| `[..., :halt]` | yes | the step whose outcome is terminal, once its write has landed. `reason` is `:done` or `:budget_exhausted`; `fail/4` and `cancel/3` reach no interpreter and emit none |
| `[..., :terminate]` | **never** | it names a GenServer callback; there is no process here, and both halves of every span arrive inside one call, so there is no open-span entry to leak |
| `[..., :macrostep, :start]` / `[..., :stop]` | yes | brackets each `Interpreter` advance call: `initialize/2` in `Runs.create/4` (`trigger: :initialize`), `handle_event/2` in `Runs.stepped/6` (`trigger: :event`), and each `deliver_internal/5` re-entry wave (`trigger: :internal`, nested, per `st-ADR-0067` decision 5) |
| `[..., :interpret]` | **never** | this package has no `st-ADR-0029` injection seam. If it grows one it emits this event rather than minting a name |
| `[..., :unroutable]` | contract only - **no emit site today** | it names an effect nothing could route: no dispatch arm, and no executor accepted its kind. The executor seam's only verdicts are `:ok` and `{:error, reason}` (`StatifierPersistence.Executor`), and `Driver`'s own dispatch ends in an accepting catch-all, so the case is absent by circumstance rather than inapplicable. An executor that accepted the effect and returned `{:error, reason}` is **not** it; that is `[:statifier_persistence, :effect, :failed]`. A seam that can refuse an effect outright emits this event rather than minting a name |
| `[..., :effect, _]` (11) | yes | every effect the advance produced, in the core's own list order, from `persist_tail/6` - lifecycle effects (`:done`, `:budget_exhausted`) included, since the bridge needs them even though the executor never sees them |
| `[..., :trace, _]` (9) | yes, under `trace: true` | the same pass; the flag rides the position (`st-ADR-0060`) and the gate stays in the core, which simply produces no trace effects when it is off |

`driver: :persistence` is on every one of them, and it is frozen (ADR-0009
decision 2). `st-ADR-0067` open question 1 left the atom to this
repository; this is the answer, and changing it later is a breaking change
to a real consumer.

The `session_id` these emitters take is the chart's own `_sessionid`, read
out of the decoded datamodel - the same read `Driver` already performs for
event origin. This package never performs an extra lookup to obtain it,
and never invents one.

`st-ADR-0067` decision 4's rule holds unchanged: **no `run_id` on this
family.** The storage key is this package's vocabulary and travels on
family two.

Two shapes a reader of the emit sites will notice, both deliberate:

- **The effect events are emitted up front, not interleaved with
  execution.** They report what the *chart* produced; what the host's
  executor then made of each one is family two's
  `[:statifier_persistence, :effect, :failed]`. Interleaving would also
  have to place the two lifecycle effects the executor never sees
  somewhere other than where the interpreter put them.
- **The `:initialize` span is the one span not nested inside a step
  span.** `Interpreter.initialize/2` runs in `Runs.create/4` before the
  per-run exclusion opens, so the bridge has no step span recorded for that
  process when it fires: it is not a child of the create's
  `[:statifier_persistence, :run, :step, :start]`/`:stop` pair, and with
  nothing of the bridge's own open around it, it is the root of its own
  trace. Every other macrostep span is emitted inside the serialized unit and
  nests as `st-ADR-0067` decision 6 expects. Both halves of every one of them
  are emitted inside one synchronous call, so decision 5's "a span never
  crosses a persist boundary" holds structurally.

## Family two: the storage-phase contract

### Conventions adopted from the family

- **Measurements are numbers; metadata is everything else**, integer-valued
  indexes included, because an opaque index has no numeric meaning to
  average. `child_index` is therefore metadata.
- **One definition site, enumerable ahead of a call.**
  `StatifierPersistence.Telemetry` builds every name from module attributes
  holding literal atoms, and `events/0` returns the full list, the way
  `Statifier.Telemetry.events/0` and `StatifierOban.Telemetry.events/0` do.
  The bridge attaches one handler per event name under its own handler id
  and cannot do that for a list it has to hand-copy. Deriving a name
  segment from a module name at runtime is forbidden for the same reason
  (and by Credo's `UnsafeToAtom`).
- **Moduledoc shape**: a one-line opener naming ADR-0009, a section per
  structural rule, then a markdown table of Event | Measurements | Metadata
  per family, with each family's emission gate stated above its table.
  Each emitter's `@doc` names the exact event it emits.
- **Amendment discipline.** Adding a measurement or metadata key to an
  existing event is an amendment and is fine; renaming or removing one,
  renaming an event, or changing the driver atom is breaking and needs a
  new ADR. A bridge that needs data these events lack gets a new field
  here - it never reaches into this package.
- **No configuration knob and no sampling knob.** Emission is
  unconditional: `:telemetry.execute/3` on an event with no handlers is a
  lookup and a return, and every option this package carries is a seam a
  host must state explicitly (ADR-0002). Nothing in this family scales with
  microstep count, so upstream's `trace: true` gate has no counterpart.

### Deliberate departures from `sob-ADR-0006`, and why

`statifier_oban` landed its half first and invited a sibling with a
genuinely different shape to say so rather than copy out of deference.
Two of its decisions do not transfer, and one does.

**Adopted: the `[:package_name, ...]` prefix**, fixed and not
configurable, because the bridge must name the events at compile time and
a per-host prefix would make its attach list depend on host configuration
it cannot see. `st-ADR-0067` decision 6 names this exact namespace
independently.

**Departure 1: the identity key is `run_id`, not `scope`.**
`StatifierOban.Timer.Key`'s scope is *either* a live session's id *or* a
host's durable run id and that package cannot tell which, so `scope` is the
only honest name available to it. Here both exist as distinct named things:
`run_id` is this package's storage key, present on every seam, and the
logical `_sessionid` is upstream's correlation key carried in the position
blob. Naming either of them `scope` would discard information this package
has. `session_id` rides where a position has already been decoded and is
explicitly `nil` otherwise.

**Departure 2: the step seam is a `:start` / `:stop` pair.** That record's
rule - no pairs - rests on Oban already owning every interval it could
bracket. This package owns an interval nobody else measures: lock, load,
decode, identity-check, advance, execute effects, persist. The upstream
macrostep span is expected to nest inside it, and the bridge's nesting needs
an outer span that is genuinely open to record in its table, which a single
event carrying a duration cannot provide. `span_ref` keeps `st-ADR-0040`
decision 2's semantics exactly: a fresh `make_ref/0` per span, on both
halves, the only pairing key. Both halves are emitted inside one function
call, so `st-ADR-0067` decision 5's "a span never crosses a persist
boundary" holds structurally.

Everything that is *not* the step seam is a single point-in-time event, on
that record's own reasoning.

### The step seam

Brackets one serialized drive - `Runs.create/4`, `Runs.step/5`,
`Runs.fail/4` or `Runs.cancel/3` inside `serialized/4`. Emitted on the
calling process. The `[:statifier, :session, :macrostep, ...]` span opens
and closes inside it.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_persistence, :run, :step, :start]` | `Runs`, immediately inside `serialized/4` | `system_time`, `monotonic_time` | `run_id`, `entry`, `span_ref` |
| `[:statifier_persistence, :run, :step, :stop]` | the same call, on every return path | `duration`, `monotonic_time` | `run_id`, `session_id`, `content_hash`, `entry`, `outcome`, `status`, `reason`, `span_ref` |
| `[:statifier_persistence, :run, :lock]` | `serialized/4`, after `strategy.with_run/3` returns or refuses | `duration` (the wait, not the held time), `system_time` | `run_id`, `strategy`, `outcome`, `reason` |

`entry` is which public door was used: `:create`, `:step`,
`:done_invocation`, `:failed_invocation`, `:answer_parent`, `:fail`,
`:cancel`. It is a fixed vocabulary and it is the dimension an operator
slices by first, because a `:done_invocation` step and a `:step` step have
different expected shapes.

`outcome` on the stop is `:ok`, `:discarded` or `:error`, mirroring the
three return shapes exactly. `status` is the run's resulting
`Adapter.run_status` (`:active`, `:completed`, `:failed`, `:cancelled`) and
is `nil` when the step did not reach a write. `reason` is the error term on
an `:error` outcome and `nil` otherwise - and it is a term, so a consumer
folding it into a metric dimension must narrow it first.

`session_id` is `nil` on the stop when the step never got as far as a
decoded position: a terminal-run discard reads the run record only, and a
lock refusal or an identity refusal never loads at all.

`[:statifier_persistence, :run, :lock]`'s `duration` is the wait for the
per-run exclusion, which is the number that says whether a host's
concurrency is fighting itself, and it is invisible from every other
surface. `strategy` is the serialization module
(`StatifierPersistence.Serialization.AdapterLock` by default); `outcome` is
`:acquired` or `:unavailable`; `reason` on `:unavailable` is the
`{:serialization, term}` payload, including
`{:serialization, :not_supported}` for an adapter that exports no
`lock_run/3`.

### The storage seam

Emitted from the `Storage` facade, above every adapter, on the calling
process.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_persistence, :adapter, :call]` | every `Storage` facade function, around the adapter call | `duration`, `system_time` | `adapter`, `callback`, `outcome`, `reason`, `run_id`, `session_id`, `content_hash` |
| `[:statifier_persistence, :identity, :refused]` | `Storage.precheck_identity/2`, every writer's identity arm, and `persist_tail/6` | `system_time` | `run_id`, `session_id`, `stage`, `reason`, `stored_content_hash`, `supplied_content_hash` |

`callback` is the `Storage.Adapter` callback name - `:init`, `:save_chart`,
`:fetch_chart`, `:save_position`, `:fetch_position`, `:insert_run`,
`:fetch_run`, `:update_run`, `:isolate`, `:lock_run`,
`:supports_metadata?`, `:list_runs_by_metadata` - a closed vocabulary
fixed by the behaviour. `adapter` is the module. Between them they answer
"which storage call is slow" without a host instrumenting its own adapter,
and they answer it for the in-memory adapter too, which no SQL tracer sees.

`outcome` is `:ok` or `:error`; `reason` carries the adapter's own error
arm (`:chart_not_found`, `:position_not_found`, `:run_exists`,
`:run_not_found`, `:metadata_unsupported`, `{:adapter, term}`) and the
facade's capability refusals (`:child_listing_unsupported`,
`:run_position_missing`, `:not_a_statifier_blob`,
`{:unsupported_format_version, term}`). Which of `run_id`, `session_id` and
`content_hash` are present is whatever that callback is keyed by;
the rest are `nil`.

`[:statifier_persistence, :identity, :refused]` is the sharpest event in
this contract. `stage` is `:position`, `:run` or `:chart`; `reason` is
`:identity_mismatch` or `:unidentified_chart`. A mismatch means a chart
revision changed under a live run - the exact drift the guard exists to
catch (ADR-0003) - and a host that cannot count it learns about the deploy
that caused it from a support ticket. **Only the two `content_hash` values
travel**, never the `Identity` structs the error term carries; see
"Cardinality and disclosure" below.

An adapter call inside a lock inside a step nests three deep in the bridge,
through its own span table, with no propagation machinery involved.

### The run lifecycle seam

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_persistence, :run, :created]` | `Runs.create/4`, after the insert | `system_time` | `run_id`, `session_id`, `content_hash`, `child?`, `metadata?` |
| `[:statifier_persistence, :run, :terminated]` | `Runs.create/4`, `Runs.step/5`, `Runs.fail/4`, `Runs.cancel/3`, on any terminal write | `system_time` | `run_id`, `session_id`, `content_hash`, `status`, `driven_by`, `reason` |
| `[:statifier_persistence, :run, :discarded]` | `Runs.step_tail/6`, `step_loaded/7`, `repair_terminal/3`, and `fail`/`cancel`'s terminal arms | `system_time` | `run_id`, `entry`, `reason`, `repaired?` |
| `[:statifier_persistence, :effect, :failed]` | `execute_effects/3` and `reenter_failures/5` | `system_time` | `run_id`, `session_id`, `content_hash`, `kind`, `executor`, `reason`, `reentered?` |
| `[:statifier_persistence, :drive, :turns_exhausted]` | `Driver`'s turn loop, on `{:turns_exhausted, n}` | `system_time`, `turns` | `run_id`, `entry` |

`driven_by` on `:terminated` is `:chart` or `:host`, and it is the reason
this event exists at all. A chart-driven termination is also a
`[:statifier, :session, :halt]`; **`Runs.fail/4` and `Runs.cancel/3` are
not**. No interpreter runs on those paths - ADR-0004 decision 6 makes
abandonment a host decision about the run rather than a chart transition -
so upstream emits nothing, and a host counting `:halt` alone would
undercount its own terminations by exactly the ones it caused itself.
`status` is `:completed`, `:failed` or `:cancelled`; `reason` is the run
record's short `failure` string, which ADR-0004 decision 1 already
constrains to be console-readable, or `nil`.

`:discarded`'s `reason` is a closed vocabulary of the three ways a
delivery becomes a non-event: `:terminal_run` (the record was already
terminal, read before any position decode), `:builder_declined` (an event
builder returned `:discard` under the exclusion), and `:position_terminal`
(`Interpreter.handle_event/2` returned `{:error, :not_running}`, the
structural backstop for a record whose `:active` status lied). Only the
third sets `repaired?: true`, and a host seeing it regularly has a
durability bug upstream of this package - which is precisely why the
repair path is worth a countable event rather than a silent fix.

`[:statifier_persistence, :effect, :failed]` is where the executor seam's
verdicts land. `kind` is the effect's kind atom, `executor` is the module
(or `:fun` for the arity-2 form), `reason` is the `{:error, reason}` term
it returned, and `reentered?` says whether ADR-0004 decision 4's
`error.communication` re-entry was opened for it - `false` for an
observational effect, whose failure is discarded because observation must
never steer a run, and `false` for a failure inside a re-entry wave, which
is single-wave by design. Nothing wraps a *successful* executor call: the
host's work is the host's to instrument, and the step span already bounds
it.

### The durable-subchart seam (ADR-0008)

Emitted on the parent's stepping process, at dispatch time.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_persistence, :child, :started]` | `Driver.start_child/3`, after `adopt_child/3` | `system_time` | `parent_run_id`, `child_run_id`, `invoke_id`, `child_index`, `content_hash`, `session_id` |
| `[:statifier_persistence, :child, :refused]` | the same chain, on any refusal | `system_time` | `parent_run_id`, `invoke_id`, `reason` |
| `[:statifier_persistence, :child, :answered]` | `Driver.answer_parent/3`, after the parent's door returns | `system_time` | `child_run_id`, `parent_run_id`, `invoke_id`, `outcome` |
| `[:statifier_persistence, :child, :cascade_cancelled]` | `Runs.cascade_cancel/3`, after the sweep | `system_time`, `count`, `retained` | `parent_run_id`, `invoke_id` |

`content_hash` on `:started` is the child's *pinned* hash - ADR-0008
decision 2's mandatory identity pin, recorded in the child's linkage
metadata - which is what lets a consumer tell a child restarted against a
redeployed chart from one that was not. `session_id` is the child's own
logical session, so the bridge can stitch the child's macrostep spans to
this event without reading `Run.Linkage`.

`:refused`'s `reason` is ADR-0008 decision 4's closed refusal set:
`:child_listing_unsupported` (the adapter cannot host children),
`:unidentified_chart` (the resolved child chart carries no identity),
`:run_exists`, and a `Statifier.Invoke.Source.resolve/2` reason. All four
reach the chart as `{:failed, reason: "child_run_creation_failed", detail:
detail}`, so a host sees them there too - but only as a chart-level
failure, without which of the four it was.

`:answered`'s `outcome` is `:done` or `:failed`, mirroring the two doors.

`count` on `:cascade_cancelled` is how many runs the sweep actually
cancelled and `retained` is how many it found already terminal and left
alone - ADR-0008 decision 5's retain semantics as a number. Both are
legitimately `0`: a cancel matching nothing is a no-op, not an error, and a
crash-recovering host may replay a cancel whose start it never durably
recorded. `invoke_id` is `nil` for the whole-parent sweep and set for the
per-invocation one.

A child is a separate run with its own logical session, so its own steps
produce their own step spans and their own macrostep spans - not children
of the parent's. Parenthood would hold the parent's trace open for the
child's whole life, which on this package's target hosts is days. The
bridge links instead, from `:started`.

## Cardinality and disclosure

Every metadata key above is bounded by the chart or by a closed vocabulary,
with two exceptions, both deliberate.

`run_id` is host-supplied and unbounded. It is present as a correlation id
for a span or a log line, **never as a metric dimension** - the same status
`job_id` has in `statifier_oban` and `id` has in Oban itself.

`reason` is a term on several events. Where this note names a closed
vocabulary (`:discarded`, `:child, :refused`, the adapter arms) it is safe
to dimension on. Where it carries an arbitrary executor or adapter error
(`:effect, :failed`, `:adapter, :call`'s `{:adapter, term}`, the step
stop), a consumer must narrow it before it becomes a dimension. A host
executor returning a per-effect struct there will blow up any metric keyed
on it, and no change here can prevent that.

**Nothing host-opaque and nothing from the datamodel is ever on an event.**
Never emitted, in any form - not truncated, not hashed, not "just the
keys": the `chart_blob`, the `position_blob`, the `identity_blob`, the
ADR-0006 `metadata` map, the chart's datamodel, an invoke's `params`, and a
`:done` effect's `donedata`.

The `metadata` map is the one a well-meaning implementer will reach for,
because it holds exactly the tenant and correlation ids an operator wants
to slice by. It is excluded anyway. It is unbounded by construction and
host-defined, so no cardinality budget can be reasoned about here; and
ADR-0006 decision 2 already records that it sits at rest in the clear
outside `:blob_type` encryption, so a host that filed something it should
not have would have it leave the database on this channel. `metadata?` on
`[:statifier_persistence, :run, :created]` is a boolean - whether a
non-empty map was supplied - and that is the whole of what this contract
says about it. A host wanting its own dimensions has `run_id` on every
event and its own table to join.

The identity guard's refusal carries the same rule into a place it is easy
to miss. The error term is `{:identity_mismatch, stored, supplied}` with
two whole `Identity` structs; the event carries the two `content_hash`
values and nothing else from them. A content hash is a digest of a chart
document and is the key this package and its host already exchange in the
open; the envelope around it is not.

`caller_context` does not appear in this family at all. This package
originates none. It rides family one from the driving event, where
`Statifier.Telemetry` puts it and where `st-ADR-0063` intends it, and the
bridge reads it there.

## The bridge half

`opentelemetry_statifier` is the only package in the family that calls an
OpenTelemetry API (`st-ADR-0062`), and it bridges siblings as separate
per-library `setup` calls. This package's half of that bridge is an
obligation, not code: the promise that the events above carry everything
the bridge needs, so it never reads a chart blob, a position blob, a run
record, `StatifierPersistence.Run.Linkage`, or an ADR-0006 metadata map.
Span construction, handler attachment and the span table are the bridge
repo's decisions and are not specified here.

What the events are built to let the bridge do:

- **Family one needs no bridge work at all.** These are upstream's own 27
  events with `driver: :persistence` in metadata, mapped to
  `statifier.driver` by the mapping the bridge already has. A durable run
  becomes visible the moment the emit sites land, with no second handler
  table and no second attribute vocabulary. That is `st-ADR-0067` decision
  1's whole argument, and this package is the reason it was made.

- **`session_id` maps to `statifier.session_id`, the same attribute
  upstream uses.** That is what joins family two's events to family one's
  spans for a consumer that is not relying on ambient context - and it is
  why family two carries the honest `nil` rather than a fabricated value on
  the events emitted before a position is decoded.

- **`run_id` maps to `statifier_persistence.run_id`**, a new attribute in
  this package's own namespace. Every other measurement and metadata key
  maps by name into `statifier_persistence.`, as upstream's attribute rule
  already specifies for its own namespace.

- **Nesting is bridge-owned, three deep.** A step span opens and the bridge
  records it in its own span table, tagged with the emitting pid; the
  adapter events and the upstream macrostep span land inside it because the
  bridge parents them from that row, never from the process's ambient OTel
  context, which it does not read (`ots-ADR-0004` decision 4). A job or
  request span a host or `statifier_oban` already had open in the same
  process therefore does not parent the step span - with nothing of the
  bridge's own open around it, the step span is the root of its own trace.
  `st-ADR-0067` decision 6 describes the shape inside it. No propagation
  machinery is involved, and no package has to know about another.

- **Resume and cross-step stitching use links, never parenthood, and the
  position blob carries nothing trace-shaped.** ADR-0009 decision 6 settles
  this. Within a node, consecutive macrosteps of one run stitch through the
  bridge's last-span-context table keyed on `session_id`, exactly as
  statifier-ex's `docs/opentelemetry.md` already stitches session macrosteps - the
  durable case is not special. Across a node or a deploy, where that table
  misses, a step links to its driving trace if and only if the host
  attached a `st-ADR-0063` `caller_context` to the driving event; with
  none, each macrostep is an unlinked trace correlated by
  `statifier.session_id`. That is the standard detached case, not an error.
  Whether this package should reserve a linkage key carrying a W3C
  `traceparent` so cross-node resumes link without host cooperation is
  deferred, with the trigger stated in ADR-0009 decision 6.

- **A child run links to its parent, and is not parented by it.** From
  `[:statifier_persistence, :child, :started]` the bridge has
  `parent_run_id`, `child_run_id`, `invoke_id`, `child_index`, the pinned
  `content_hash` and the child's `session_id` - everything needed for a
  link, with nothing read out of `Run.Linkage`. Parenthood would hold the
  parent's trace open for the child's whole life.

- **`trigger` is a pass-through string.** No event here originates one, but
  the macrostep events this package emits through `Statifier.Telemetry`
  carry upstream's, and it is copied and never validated against an enum.
  statifier-ex owns that vocabulary and is still growing it (`:resume` is
  the most recent addition); a consumer that hardcodes today's value set is
  wrong on the next release.

- **Trace-off degrades to nothing, structurally.** With no bridge attached,
  `:telemetry.execute/3` on an event with no handlers is a lookup and a
  return. There is no build-time flag, no compile-time removal, and no
  option to disable emission. Upstream's `trace: true` gate applies to
  upstream's nine `:trace` events and rides the position (`st-ADR-0060`);
  nothing in family two scales with microstep count, so it has no
  counterpart here.

## For a host that is not using the bridge

The events are plain `:telemetry`. A host attaching `Telemetry.Metrics`
gets, with no OpenTelemetry anywhere:

- a distribution over `[:statifier_persistence, :run, :step, :stop]`'s
  `duration`, dimensioned by `entry` and `outcome` - the durable stepper's
  own latency, which nothing else measures;
- a distribution over `[:statifier_persistence, :run, :lock]`'s `duration`
  and a counter on its `outcome` - whether the host's concurrency is
  fighting itself for the same run;
- a distribution over `[:statifier_persistence, :adapter, :call]`'s
  `duration` by `callback` - which storage call is slow, in-memory adapter
  included;
- a counter on `[:statifier_persistence, :identity, :refused]` - the
  deploy-drift alarm, which should normally be flat at zero;
- counters on `[:statifier_persistence, :run, :terminated]` by
  `driven_by` and `status`, and on `[:statifier_persistence, :run,
  :discarded]` by `reason`;
- counters and a `count` distribution on the child seam - fan-out,
  refusals, and how much a cascading cancel actually swept.

That is why the contract is defined in events rather than spans, and it is
the same reason `st-ADR-0062` gave for the bridge being a separate package.
