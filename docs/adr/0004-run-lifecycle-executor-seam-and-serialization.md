# ADR-0004: Run lifecycle, the executor seam, and per-run serialization

Status: accepted (2026-08-22)

## Context

The charter's loop is this package's reason to exist: load a persisted
position, step it, execute the effects, persist (sp-4an.2, restating the
charter's scope bullets 2 and 3). sp-4an.1 shipped the substrate - the
blobs-only adapter behaviour and the guarded facade (ADR-0003) over the
keys ADR-0002 fixed - but nothing in the package yet knows what a run is,
calls the interpreter, or executes an effect. This record fixes the
contracts the loop code will encode: the durable run record, the loop's
order, the seam through which effects reach a host, and the seam through
which concurrent deliveries to one run are ordered.

The engine facts this record leans on, verified against the vendored pin
(`deps/statifier/`, `mix.lock`):

- `Statifier.Interpreter.initialize/2` returns an untagged
  `{MachineState.t(), [Effect.t()]}` pair and cannot fail
  (`deps/statifier/lib/statifier/interpreter.ex:259-260`). Creating a run
  therefore always has a machine state in hand, even when that state is
  already terminal or budget-exhausted.
- `Statifier.Interpreter.handle_event/2` returns
  `{:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}`, with
  the `running: false` refusal as the head clause
  (`interpreter.ex:477-502`). Terminality is a typed refusal at the core,
  never an exception.
- `Statifier.Interpreter.deliver_internal/5` is st-ADR-0039's re-entry
  seam: the one door through which an out-of-loop failure becomes an
  internal `error.*` event, delegating to the same two internal-queue
  writers the core's own executable content uses and folding to quiescence
  (`interpreter.ex:505-545`). This package never constructs `error.*`
  events by hand.
- `Statifier.Position.to_binary/1` refuses only `:unidentified_chart` and
  does not check quiescence; that check belongs to `export/1`
  (`deps/statifier/lib/statifier/position.ex:105-117, 267-277`).
  Quiescence before persist is therefore this loop's own assertion, not
  something upstream enforces for it.
- st-ADR-0064 makes `from_binary/2` drop `routes` and `invoke_types`
  unconditionally on decode (`position.ex:164-180`), so re-stamping both
  on every load is structural, not a convention: the loop can assert the
  fields arrive `nil` and fail loudly if upstream ever regresses.
- st-ADR-0054 decision 3's deterministic dedup key
  (`{scope, send_id, macrostep, microstep, round, c_index, owner,
  ordinal}`) and st-ADR-0059's `timer_counter` ordinal make at-least-once
  honest: a re-driven step re-emits effects carrying identical keys, so
  idempotency can live with the consumer.
- The interpreter moduledoc's "Rehydrating a position" recipe
  (`interpreter.ex:43-92`) is this loop's resume spec: `from_binary/2`,
  then `put_routes/2` + `put_invoke_types/2`, then an advance entry; no
  `initialize/2` call on the resume path, ever.

Accepted records that bound the design: this repo's ADR-0002 (runs
vocabulary, engine identities verbatim, surrogate keys are Ecto-layer
only) and ADR-0003 (blobs-only behaviour, guard in the facade, engine
identities as the only keys); upstream's st-ADR-0052/0054/0059/0060/0064
(identity, effect-vocabulary consumption, timer ordinal, resume
semantics, blob field drops), adopted by reference per ADR-0001.

## Decision

**1. The run record owns its current position.** A run is the durable
unit: `%{run_id, status, content_hash, identity_blob, position_blob,
failure}`. Storing the position on the run row (rather than a second
lookup into the sp-4an.1 position table) makes the persist tail one
adapter write, makes the per-run lock cover exactly the bytes it
protects, and matches ADR-0002 decision 4/5's `statifier_runs` sketch.
The sp-4an.1 chart/position callbacks stand unchanged for hosts
persisting sessions without the lifecycle. `position_blob` is nullable: a
run that fails at creation (budget exhaustion during `initialize/2`) has
no quiescent position to store, and persisting a non-quiescent one is the
bug the loop exists to prevent. The adapter behaviour gains three
callbacks - `insert_run/2`, `fetch_run/2`, `update_run/2` - and two error
arms, `:run_exists` and `:run_not_found`. ADR-0003's blobs-only rule
binds all three: no callback decodes a blob, validates a status
transition, or performs an identity check - the facade and the lifecycle
own those.

**2. Run keys and statuses stay this layer's style: opaque and total.**
`run_id` is a caller-supplied opaque string stored verbatim - a host
identity in ADR-0002 decision 1's category, not a surrogate this layer
generates. `status :: :active | :completed | :failed` and
`failure :: String.t() | nil` (a short reason; structured detail is not
portably storable and belongs in host telemetry). Uniqueness is the
adapter's: `insert_run/2` refuses a duplicate with
`{:error, :run_exists}`, which is what makes create-exactly-once
checkable without a lock. The identity guard extends structurally, not by
convention: the new facade functions mirror sp-4an.1 exactly - writers
derive `content_hash` and `identity_blob` from the machine state's own
`Machine.identity/1` (never a caller value) and refuse
`:unidentified_chart`; the read path (`load_run_position/3`) reuses the
same identity pre-check and `Position.from_binary/2` as
`load_position/3`, so ADR-0003 decision 2's claim - no adapter ever holds
both sides of the guard - stays true for run records too.

**3. The loop's order is the contract.** A step is: liveness check on the
run record -> load (guarded) -> re-stamp `routes`/`invoke_types`
unconditionally (with the nil tripwire from st-ADR-0064: the fields are
pattern-matched `nil` before stamping, so an upstream regression fails
loudly here, not silently downstream) -> step via
`Interpreter.handle_event/2` -> execute effects via the executor seam ->
consume `:done` and `:budget_exhausted` into run status -> assert
`MachineState.internal_queue_empty?/1` -> persist. At-least-once effect
execution is a property, not a bug: a crash between step and persist
re-drives the same event and re-emits the same effects with identical
deterministic keys (st-ADR-0054 decision 3, st-ADR-0059), and the loop
never dedupes - idempotency is the consumer's. An event delivered to a
terminal run is discarded with a typed `{:discarded, run}` result, never
an exception and never a silent step; the check runs on the run record
before any position decode, with `handle_event/2`'s `:not_running` arm as
the structural backstop.

**4. The executor seam is the effect vocabulary and nothing else.** A
behaviour with one required callback,
`execute(effect :: Statifier.Effect.t(), context :: map()) ::
:ok | {:error, term()}`, invoked per effect in list order; an arity-2 fun
is accepted anywhere a module is. Only the public core effect vocabulary
crosses the seam - never Session instruction tuples (st-ADR-0054 decision
1). The loop consumes `:done` and `:budget_exhausted` itself and hands
everything else over. Failures map by upstream's own classification axis
(st-ADR-0051's table, st-ADR-0039's seam): the core raises
`error.execution` itself at planning time before any effect is emitted,
so every failure an executor can report is a failure to reach or act on
the outside world after the core accepted the effect - and re-enters
uniformly as `error.communication` through
`Interpreter.deliver_internal/5`, for actionable effects of both the
invoke class (`:invoke`, `:cancel_invoke`, `:autoforward`) and the send
class (`:send`, `:send_delayed`, `:cancel`). Failures on observational
effects (`:log`, `:datamodel_*`, trace) are discarded, because
observation must never steer a run. This package never mints
`error.execution`. Re-entry is single-wave per step: effects emitted by
the error re-entries are executed, but their failures are not re-entered
again - they surface in the returned run's step result - so a
deterministically failing executor cannot loop the library.

**5. Per-run serialization is a pluggable strategy, not a property of the
loop.** A behaviour `StatifierPersistence.Serialization` with
`with_run(config, run_id, fun) :: {:ok, term()} | {:error, term()}`; the
loop runs its whole load-to-persist tail inside `with_run/3`. The default
strategy, `StatifierPersistence.Serialization.AdapterLock`, delegates to
a new optional adapter callback `lock_run/3` (declared like `isolate/1`),
and refuses with `{:error, {:serialization, :not_supported}}` when the
adapter does not export it. The Ecto adapter implements `lock_run/3` as a
row lock (sp-4an.3); a job-queue host later swaps the strategy without
touching the loop - the ordering guarantee moves, the API does not. That
no-API-change swap is the acceptance test for this shape.

**6. Completion is chart-driven.** The `:done` effect is the only path to
`:completed`; there is no public `complete/2`. A host that must end a run
early has `fail/4` (abandonment with a reason), the only host-driven
terminal transition, and it involves no interpreter call - abandonment is
a host decision about the run, not a chart transition.

## Consequences

- What would reopen this record: an effect the lifecycle must consume
  beyond the two named (`:done`, `:budget_exhausted`); a serialization
  strategy that cannot express its guarantee as `with_run/3`; upstream
  moving quiescence enforcement into `to_binary/1`, which would make
  decision 3's assertion redundant or conflicting. `caller_context`
  (st-ADR-0063) landing upstream is NOT a reopener: effect structs pass
  through the seam verbatim, so the field arrives here for free when the
  pin moves.
- Deliberately omitted, on the same unexercised-contract reasoning
  ADR-0003's Consequences records: effect deduplication (at-least-once is
  the contract and a deduping loop would hide it), run deletion and
  `delete_position`, position history, and an operator-forced manual
  complete (a deliberate future API, recorded then, if a real embedder
  needs it).
- Durable timers and async invoke execution stop at the seam:
  `:send_delayed`, `:cancel`, `:invoke`, `:cancel_invoke`, `:autoforward`
  cross it and scheduling them durably is statifier_oban's charter
  (st-ADR-0054) or the host's. Resume restores position, not liveness
  (st-ADR-0060 decision 7).
- The Ecto adapter (sp-4an.3) inherits three run callbacks, two error
  arms, and an optional `lock_run/3` to implement as a transaction-scoped
  row lock, all conformance-tested through the sp-4an.1 suite.

## Amendment (2026-08-22, sp-4an.3.1): the Ecto lock is advisory plus row

Decision 5 (and the Consequences bullet above) named the Ecto adapter's
`lock_run/3` a transaction-scoped row lock. Implementing it showed the
row lock alone cannot honor the callback's contract: `SELECT ... FOR
UPDATE` excludes nothing when no run row matches, and the contract (with
the conformance suite's lock tests) requires mutual exclusion for a
`run_id` that has not been inserted yet.

So the Ecto adapter's transaction takes
`pg_advisory_xact_lock(hashtextextended(run_id, 0))` first -
unconditional per-run exclusion, row or no row - and then locks the run
row with `SELECT ... FOR UPDATE` when it exists, keeping this decision's
ordering against the row itself. Both are transaction-scoped, so any
exit from `fun` (a raise included) releases them with the transaction.
The rowless hole and the fix are pinned by a live two-connection test
outside the SQL sandbox, whose single shared connection would otherwise
serialize the callers by ownership and mask a broken lock.

## Validation note (2026-08-22, sp-4an.4): driven end to end by a demo embedder

Decisions 3, 4 and 6 were exercised end to end by a demo embedder
(`test/statifier_persistence/demo/`, walkthrough in
`docs/restart-demo.md`) running a multi-step chart across a simulated
restart with no Session process - persist mid-run with a pending durable
timer and an in-flight async invocation, drop everything volatile, boot
from the run id alone, recover, finish - over both adapters, with the
executor call log asserted on exact contents and a replay reproducing
the path struct for struct. Not an amendment: nothing decided here
changes.

One finding about the API surface: a byte-identical replay needs the
session id, the one input `Runs.create/4` otherwise generates fresh
(`MachineState.new/2` stamps it into the `:datamodel_init` effect's
`_sessionid`/`_ioprocessors` system variables). The existing
`initialize: [session_id: ...]` pass-through already covers it - no new
surface needed - but a host that wants replayable runs must record that
id alongside its input tape, which `docs/restart-demo.md` now says out
loud.

## Amendment (2026-09-01, sp-x8c): decision 3's event argument gains a builder arm

ADR-0007 decision 4 widens `Runs.step/5`'s `event` parameter from
`Event.t()` to `Event.t() | event_builder()`, where a builder is a fun over
the loaded, re-stamped `MachineState` returning `{:ok, event}` or
`:discard`. This record's decision 3 named the argument an event and fixed
the loop's order around it, so the widening belongs here as well as there;
until now the cross-reference lived only in 0007, which is the wrong
direction for a reader who arrives at the lifecycle record first.

The amendment is to the argument's type, **not** to decision 3's step
order. ADR-0007 is explicit that the arm is additive: the named steps still
run liveness check -> load -> re-stamp -> step -> effects -> status ->
persist, and the builder only late-binds the event argument to the step
that was already going to happen. A builder that declines writes nothing
and executes nothing, so it lands on decision 3's own `{:discarded, run}`
result rather than inventing a fourth outcome. Every caller passing an
`%Event{}` is unaffected.

Read ADR-0007 for why the arm exists - the liveness read against
`active_invocations` has to be taken inside `with_run/3` (decision 5) under
the same exclusion as the step it gates, which is only expressible if the
event is built after the load.
