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

## Note (2026-09-06, sp-n8g): decision 6's "the `:done` effect is the only path to `:completed`" is one-directional

Recording clarification only. Nothing in the decisions above changes; the
sentence is exact and stays exact, and this note is here because its
converse is about to stop holding and a reader who assumed the converse
would be surprised by the code.

Decision 6 says two things and this note touches only how they are read.
"The `:done` effect is the only path to `:completed`" says that nothing
*except* a `:done` effect can complete a run, and that remains true. It
does not say that a `:done` effect always completes one, and after
ADR-0008's 2026-09-06 amendment (`sp-n8g`) it will not: a chart that
settles in a final tagged failure-classed in its own `<donedata>` produces
the same single `:done` effect and takes `:failed` instead. The tie-break
sits in `StatifierPersistence.Runs`' `run_status/2` and nowhere else, so
the arm order there - budget, then the failure tag, then `:done` - is the
whole of the difference.

**Note (2026-09-06, `sp-ive`):** the future tense above has come due. That
amendment is accepted and implemented (`sp-hia`), so a `:done` effect no
longer always completes a run, and `run_status/2` decides in exactly the
order named.

Decision 6's second half is untouched in both readings. `fail/4` remains
"the only host-driven terminal transition", because a failure-classed
final is not host-driven: it is the chart saying so, in the same breath it
reaches its final, through the same effect. That is the point of putting
the tag on the chart rather than adding a public `complete/2`-shaped
counterpart for failure, which decision 6 refused and this note does not
reopen.

The Consequences list above is likewise unmoved. Its reopener is "an
effect the lifecycle must consume beyond the two named (`:done`,
`:budget_exhausted`)", and the amendment adds no third effect - it reads a
field of the first one.

## Note (2026-09-13, sp-478): `run` in this record is the noun now called `execution`

Pure addition: nothing above is edited, and the lifecycle this record decides
is read at the dates its sections were decided.

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

The lifecycle entry points this record names are `StatifierPersistence.Executions`'s
`create/4`, `step/5`, `fail/4` and `cancel/3` at `71537dc`; the per-`run`
exclusion of decision 5 is the per-execution exclusion, reached through
`c:StatifierPersistence.Serialization.with_execution/3`.

## Note (2026-09-20, sp-l4p): the executor seam under host-registered send types

Pure addition: nothing above is edited. Decision 3's order and decision 4's
seam are unchanged by `send_types:`; this note says where a registered
type's effects arrive and who owns the half the core does not.

**A registered type adds no effect and no seam.** The split the persist
tail makes is still `:done` and `:budget_exhausted` to the lifecycle and
everything else to the executor, so `{:send, _}` and `{:send_delayed, _}`
of a registered type, and the `{:cancel, _}` that names such a send, reach
a host exactly where every other executable effect does -
`lifecycle_effect?/1`, `lib/statifier_persistence/executions.ex:1773`, read
at `85d863b`. The Consequences' reopener, "an effect the lifecycle must
consume beyond the two named", is not triggered.

**The host builds the event.** For a send of a registered type the event
is `Statifier.Send.Event.build/3`'s, called by the host: statifier 2.6.0's
moduledoc for that function states that a host driving
`Statifier.Interpreter` with no session reads the effect off the core and
calls it itself, where `Statifier.Session` would have called it and handed
the result to a processor. Nothing in this package calls it, and nothing
in this package should: the event is the host's to address.

**The host routes a send by `type` and a cancel by its own record.**
`%Statifier.Effect.Send{}` and `%Statifier.Effect.SendDelayed{}` each carry
the registered `type` string, so a host dispatches on it and treats
`target` as the processor's opaque route string.
`%Statifier.Effect.Cancel{}` carries no `type` field at all (statifier
2.6.0, `Statifier.Effect.Cancel`) - so a cancel names a delayed send and
not a processor.

**Holds are Session-only state, so a process-less host owns cancel
routing.** The record of which processor was handed which delayed send id
is the live session's, and statifier 2.6.0's `Statifier.Send.Processor`
moduledoc states it is not part of the persisted position, so a resumed
session holds nothing. This package resumes from a position on every step
by decision 3's order and therefore never holds it either. A host that
issues a delayed send of a registered type keeps its own record, keyed by
the send id and its session scope, and a `%Statifier.Effect.Cancel{}`
crossing this seam is routed from that record.

**`Statifier.Send.Processor` is not this package's seam.** Its `deliver/3`
and `cancel/2` are `Statifier.Session.Effects.plan/2`'s planning callbacks
(statifier 2.6.0, that behaviour's moduledoc), and there is no session
here. What a module registered in a `send_types:` map is read for on this
path is the optional `ioprocessors_entry/1` alone.

**The snapshot is stamped, never stored.** `send_types` joins `routes` and
`invoke_types` as a field the position blob drops (st-ADR-0064), so the
tripwire decision 3 names now matches all three fields before the
re-stamp - `lib/statifier_persistence/executions.ex:1146`, read at
`85d863b` - and `step_loaded/8` re-stamps it from `send_types:` six lines
below (`:1152`, same read). On a create there is no stored position to
stamp, so the snapshot travels inside `initialize:`
(`StatifierPersistence.Driver.initialize_opt/3`,
`lib/statifier_persistence/driver.ex:493`, read at `85d863b`). That routing
is required rather than symmetric: `Statifier.MachineState.new/2` is the
only writer of the `_ioprocessors` entry a registered type gets, and
`Statifier.MachineState.put_send_types/2` does not rewrite it (statifier
2.6.0, that module's moduledoc), so a create that stamped outside
`initialize:` would leave `_ioprocessors` short of the host's own types for
the life of the execution.

## Note (2026-09-23, sp-g7q): a nested transaction takes no savepoint, and a host callback inside the lock must not raise

Pure addition: nothing above is edited. Decision 5's Ecto lock is a
transaction that spans `fun` (the 2026-08-22 Amendment), and `fun` is
the whole tail `StatifierPersistence.Executions` runs inside its own
`serialized/5` (`lib/statifier_persistence/executions.ex:1554`, read at
`af0cb5c`). Everything that tail reaches through the same repo from the
same process is therefore a nested transaction. This note records what
nesting does and does not give, the rule it puts on a host callback, and
where this package stands against it.

**The cause: a nested transaction drops its options.** This repository's
`mix.lock` resolves db_connection 2.10.2. `DBConnection.transaction/3`'s
clause for a connection that is already in a transaction is
`def transaction(%DBConnection{conn_mode: :transaction} = conn, fun, _opts)`
(`lib/db_connection.ex:1082` in that release): it runs `fun` on the open
connection and ignores every option. ecto_sql 3.14.0 hands a
`Repo.transaction/2` call's options to that function unchanged
(`Ecto.Adapters.SQL`, `checkout_or_transaction/4`), so
`mode: :savepoint` on a nested `Repo.transaction/2` is dropped without a
word and no `SAVEPOINT` is issued. The same clause marks the transaction
failed when the nested `fun` raises or calls `rollback/1`, and the
outermost call then rolls back: it re-raises a raise that reaches it,
and answers `{:error, :rollback}` when the nested failure was returned or
rescued on the way out. Either way a failure inside a nested
`Repo.transaction/2` is never contained to that call, it is the
enclosing transaction's.

**The remedy: an explicit SQL savepoint bracket.** Work that must be able
to fail without taking the enclosing transaction down issues
`SAVEPOINT <name>` itself, runs its statements, and ends with
`RELEASE SAVEPOINT <name>` on success or `ROLLBACK TO SAVEPOINT <name>`
on failure, each through `Repo.query!/2`. That is what statifier_router
does at its executor seam (`StatifierRouter.Delivery.deliver_event/4`,
that repository's `docs/adr/0005-routes.md`). The bracketed work must
not itself call `Repo.transaction/2` and fail: that failure goes through
the clause above and marks the enclosing transaction failed whatever the
SQL savepoint has restored.

**The boundary: a host callback reached inside `serialized/5` must not
raise.** The host code that runs inside the lock is the executor, handed
every executable effect (`execute_effects/3`,
`lib/statifier_persistence/executions.ex:2361`, through
`StatifierPersistence.Executor.run/3`, `lib/statifier_persistence/executor.ex:50`,
both read at `af0cb5c`), and an event builder, handed the loaded
position (`resolve_event/2`, `lib/statifier_persistence/executions.ex:1745`,
read at `af0cb5c`). A failure it can report it returns: an executor's
`{:error, reason}` re-enters the chart as decision 4 says, and a builder
declines with `:discard`. If one raises instead, the raise propagates
out of `serialized/5` and out of the door the host called. On the Ecto
adapter the lock's transaction is lost with it: rolled back when the
lock's transaction is the outermost, and marked failed by the clause
above when it is nested in a caller's own, so that the caller's
transaction is rolled back as well, re-raising or, if the caller
rescued the raise, answering `{:error, :rollback}`. The same is true of a
callback that runs a nested `Repo.transaction/2` which rolls back and
then returns normally: the step goes on, and its own next write raises
on the failed transaction, which db_connection's documentation for
`transaction/3` says every query does until the outermost call returns.
This package does not convert such a raise into an error: by the time
it could, the transaction it would be
reporting on is already gone, and an error answer would suggest a step
that could be retried or committed when neither is so. The contract the
README's "Writing inside a caller's transaction" section states is
unchanged; this is the part of it a callback author owns.

**The audit: nothing here relies on `mode: :savepoint`.** At `af0cb5c`
no file under `lib/` passes `mode:` to a transaction and none calls
`rollback/1`. The Ecto adapter opens exactly three transactions, each of
which can nest:

- `lock_execution/3` (`lib/statifier_persistence/storage/ecto.ex:1075`,
  read at `af0cb5c`) is decision 5's lock. It joins a caller's
  transaction by design, and that is the README contract above.
- `save_chart/2` (`lib/statifier_persistence/storage/ecto.ex:144`, read
  at `af0cb5c`) reads the tombstone and inserts with
  `on_conflict: :nothing`. Its refusal is a returned value and writes
  nothing, so it never needs to undo anything.
- `retire_chart/3` (`lib/statifier_persistence/storage/ecto.ex:774`,
  read at `af0cb5c`) keeps every refusal a returned value for the same
  reason, and its own comment says why it calls no `rollback/1`.

None of the three needs a savepoint, because none of them has a failure
it means to contain: each either succeeds, answers a refusal that wrote
nothing, or raises into its caller under the boundary above. Two
failures that are not contained are already documented as such: an
`:execution_exists` refusal inside a caller's transaction is a failed
`INSERT` that Postgres itself aborts the transaction over (the README
section above, pinned by
`test/statifier_persistence/ecto/caller_transaction_test.exs`), and
ADR-0015's `c:write_tree_migration/2` decides that an adapter reached
inside an enclosing transaction rolls that transaction back on purpose,
because a returned error would commit a partial write. Outside
`serialized/5`, `StatifierPersistence.PinSource`'s private `ask/3`
(`lib/statifier_persistence/pin_source.ex:146`, read at `af0cb5c`)
rescues a raising pin source into a `{:raised, exception}` refusal. That
conversion is sound for the retirement it refuses, but it cannot restore
a caller's transaction that a source's own nested repo work has already
marked failed; a host that calls `Executions.retire_chart/4` inside its
own transaction gets the refusal and a failed transaction together.

## Amendment (2026-09-26, sp-a2ee): a door called from inside its own executor refuses

Status of this amendment: accepted (2026-09-27, sp-a2ee). The record above
stays accepted; this amendment is proposed until the operator accepts it.

Pure addition: nothing above is edited. Decision 3 runs the executor
inside the step, after the position is loaded and before the new one is
written, and decision 5 runs that whole tail inside the execution's
serialization strategy. Neither says what happens when the executor
calls back into the execution it is being run for. Until this
Amendment the answer was a lost update: a nested door read the position
the outer step had not written yet, wrote its own, and the outer step's
write then replaced it, with nothing reported. The Ecto adapter's lock
did not stop the nested call, because the advisory lock it takes is
transaction-scoped (`lock_execution/3`,
`lib/statifier_persistence/storage/ecto.ex:1453`, read at `f756277`)
and the nested call runs in the same connection's transaction, where
Postgres grants the lock again to the session already holding it. The
in-memory adapter's lock is not re-entrant (`lock_execution/3`,
`lib/statifier_persistence/storage/in_memory.ex:757`, read at
`f756277`), so there the nested call waited on its own caller forever.

**The rule.** For the length of each executor call - one
`StatifierPersistence.Executor.run/3`
(`lib/statifier_persistence/executor.ex:50`, read at `f756277`) - the
execution is marked as in a step in the calling process. The mark is
set and cleared by `in_step/2` in `StatifierPersistence.Executions`,
which restores it on every exit from the call: a return, a raise, a
throw or an exit. Every public door of `StatifierPersistence.Executions`
that takes an execution id checks the mark first, before it reads or
writes anything, in `not_in_step/1`. The doors are `create/4`,
`step/5`, `fail/4`, `cancel/3`, `unpark/3`, `migrate/4`,
`migrate_tree/4` and `inputs/2`; `migrate_tree/4` checks its root and
every id its `plans` name.

**The error.** A door called for a marked execution answers
`{:error, {:reentrant_step, execution_id}}`, a new arm of
`t:StatifierPersistence.Executions.error/0`. It is an error rather than a
discard because nothing about the execution is wrong: the call came
from the one place it cannot be served, and the outer step goes on to
persist normally. A host that needs the nested effect records the
intent in its executor and acts on it after the outer door has
returned.

**What the rule leaves alone.** The mark names execution ids, so a door
called for a different execution from inside an executor proceeds as
before, and the mark is a list: an executor that steps a second
execution marks both until each call returns. The mark belongs to the
calling process, so a call from another process is not refused; it
meets the serialization strategy as it always did. A host that never
calls back into the execution it is stepping sees no change. Doors that
take no execution id (`cascade_cancel/3`, `migrate_batch/3`,
`retire_chart/4`, `executions_on/2`) check nothing themselves; where one
reaches a marked execution through `cancel/3`, `migrate/4` or
`migrate_tree/4`, that door's refusal is what it gets.

**Why here.** The guard sits above every adapter and every strategy,
like ADR-0003's identity guard, so both adapters answer the same: the
refusal comes before any lock is asked for. The conformance suite
carries one case for it (`StatifierPersistence.Testing.StorageConformance`,
"facade: a door called from inside its own execution's executor
refuses, and the outer step is stored").

## Note (2026-09-27, sp-zwxf): the sp-a2ee Amendment is accepted

The operator authorized the acceptance of the 2026-09-26 sp-a2ee
Amendment on 2026-09-27, after the code that implements it (`16b5613`)
shipped in statifier_persistence 0.21.0 (tag `v0.21.0`, `78aedd7`,
published on Hex 2026-09-27) under an Added changelog line. That
Amendment's own status line flips in place from proposed to accepted, and
the record above stays accepted. Its "this amendment is proposed until the
operator accepts it" is met here and stays as written. Every cite below
was read on `main` at `bb169b7`, in `lib/statifier_persistence/executions.ex`
unless another file is named; nothing under `lib/` or `test/` changed
between `v0.21.0` and `bb169b7`.

What was re-read before the flip:

- **The mark.** `in_step/2` puts the execution id at the head of a
  per-process list for the length of one executor call and restores the
  list in an `after` clause, so a return, a raise, a throw and an exit all
  restore it; `execute_one/4` wraps each `Executor.run/3` call in it.
- **The guard.** `not_in_step/1` is the first clause of the `with` in
  `create/4`, `step/5`, `fail/4`, `cancel/3`, `unpark/3`, `migrate/4`,
  `migrate_tree/4` (over its root and `Map.keys(plans)`) and `inputs/2`,
  and those are every public function of the module that takes an
  execution id; `ended?/1` takes an `%Execution{}`.
- **The error.** `t:StatifierPersistence.Executions.error/0` carries the
  `{:reentrant_step, execution_id()}` arm.
- **What the rule leaves alone.** `cascade_cancel/3`, `migrate_batch/3`,
  `retire_chart/4` and `executions_on/2` call `not_in_step/1` nowhere;
  `cascade_cancel/3` reaches an execution through `cancel/3`
  (`cancel_counted/3`), `migrate_batch/3` through `migrate/4` or
  `migrate_tree/4` (`apply_one/2`, `apply_tree/2`), and `retire_chart/4`
  and `executions_on/2` through no door of this module.
- **The adapters' locks.** The Ecto adapter's `lock_execution/3` takes
  `pg_advisory_xact_lock` inside `repo.transaction/1`
  (`lib/statifier_persistence/storage/ecto.ex`, `lock_execution/3`), and
  the in-memory adapter's spins in `acquire_lock/2` while the id is held
  (`lib/statifier_persistence/storage/in_memory.ex`, `acquire_lock/2`).
- **The conformance case.** `StatifierPersistence.Testing.StorageConformance`
  carries "facade: a door called from inside its own execution's executor
  refuses, and the outer step is stored".

The Amendment's line cites are right at `f756277`, the SHA they name. On
`main` at `bb169b7` `Executor.run/3` starts at line 55 of
`lib/statifier_persistence/executor.ex`, below the callback doc the
Amendment's own change added; the two `lock_execution/3` lines are
unchanged. The cites stay as written, and this Note is how they are read.

## Note (2026-09-27, sp-62q0): an event builder handed to `step/5` carries the in-step mark

The 2026-09-26 Amendment's rule marks the execution for the length of each
executor call. One line is added to that rule: the execution is marked as
well for the length of the call to an event builder handed to `step/5`,
and a door that takes an execution id refuses a marked id from inside the
builder exactly as it does from inside an executor.

The builder of the 2026-09-01 Amendment runs inside the step, after the
position is loaded and before the new one is written, which is the point
the Amendment's lost update comes from: a builder that called a door for
its own execution had that door's write replaced by the outer step's, with
nothing reported. Every cite below is in
`lib/statifier_persistence/executions.ex` and was read at `8d35eff`, before
this Note's change: `step_loaded/8` calls `resolve_event/2`, which calls
the builder, outside `in_step/2`, whose only caller was `execute_one/4`.
With this Note `step_loaded/8` runs `resolve_event/2` inside `in_step/2`
for the execution being stepped.

Nothing else in the Amendment moves. The error is the same
`{:error, {:reentrant_step, execution_id}}`, the doors are the same, a
door called for a different execution id from inside a builder proceeds,
and a call from another process is not refused. A builder that calls no
door for its own execution, and a caller passing an `%Event{}`, see no
change.

## Note (2026-09-27, sp-4wwq): a dry run of `migrate_batch/3` refuses the execution being stepped

The question this Note answers: a dry run of `migrate_batch/3` started
from inside an executor, over the hash of the execution that executor is
stepping - does it refuse that execution or preview it? It refuses it.

The 2026-09-26 Amendment's refusal sits on the public doors that take an
execution id. `migrate_batch/3` takes none, and its apply reaches each
execution through `migrate/4` or `migrate_tree/4`, which refuse a marked
id (`apply_one/2`, `apply_tree/2`). Its dry run reached each execution
through no door: every cite below is in
`lib/statifier_persistence/executions.ex` and was read at `fb277f6`,
before this Note's change, where the dry-run clause of `batch_one/3`
calls the serialization strategy's `with_execution/3` around `preview/3`
and checks no mark. From inside the executor the in-memory adapter's lock
waited on its own holder, and the Ecto adapter's advisory lock, re-entrant
for the connection holding it, admitted the dry run to read the execution
inside the outer step.

With this Note the dry-run clause of `batch_one/3` runs `not_in_step/1`
for the execution id before it asks the serialization strategy for
anything, and a marked id answers `{:would_refuse, {:reentrant_step,
execution_id}}`, the refusal the apply answers as
`{:refused, {:reentrant_step, execution_id}}` for the same execution. It
is counted under the dry run's existing `:would_refuse` key, and nothing
is read or written for it. ADR-0017 decision 2 already answers
`{:would_refuse, reason}` with `migrate/4`'s own refusal as `reason`, so
its option set, its outcomes and its counts are unchanged.

Nothing else in the Amendment moves. The error is the same
`{:reentrant_step, execution_id}`, the doors are the same, the other
executions the dry run lists are previewed as before, a batch that
does not list the execution being stepped answers as before, and a call
from another process is not refused. The acceptance Note's "What the rule leaves alone" line,
which names `migrate_batch/3` among the functions that call
`not_in_step/1` nowhere, is read with this Note: the batch's dry run now
calls it once per execution it lists. The tests are in
`test/statifier_persistence/executions_migrate_batch_test.exs`, over both
shipped adapters, under "from inside an executor (ADR-0004's re-entrancy
rule)".

## Note (2026-09-28, sp-hf3s): `inputs/2` is refused for a uniform rule, not for a lost update

The 2026-09-26 Amendment gives its reason as a lost update: a nested door
read the position the outer step had not written yet, wrote its own, and
the outer step's write then replaced it. That reason fits the doors that
write. `inputs/2` writes nothing, and it is on the Amendment's list of
doors all the same. This Note says why; it decides nothing.

Before the Amendment's change `inputs/2` was one call to
`Storage.list_inputs/2`, with no mark to check and no lock to ask for,
and its doc called it "Read-only and outside the execution's exclusion by
design" (`inputs/2`, `lib/statifier_persistence/executions.ex`, read at
`f756277`, the parent of the Amendment's code); the doc says so still at
`2e65d8b`. Called from inside the executor it answered on both shipped
adapters. The Ecto adapter read the execution's input log
(`list_inputs/2`, `lib/statifier_persistence/storage/ecto.ex`, read at
`f756277` and unchanged at `2e65d8b`). The in-memory adapter keeps no
input log, so `Storage.list_inputs/2` answered `:not_supported` without
calling the adapter
(`list_inputs/2` and `input_log_supported?/1`,
`lib/statifier_persistence/storage.ex`, read at the same two SHAs). So
`inputs/2` had no write to lose, and, taking no lock, it did not wait on
its own caller either.

It is refused because the rule is uniform. The Amendment states it over
every public door of `StatifierPersistence.Executions` that takes an
execution id, not over the doors that write, and `inputs/2` takes one:
it runs `not_in_step/1` first, before it reads anything, and answers
`{:error, {:reentrant_step, execution_id}}` for the execution being
stepped (`inputs/2` and `not_in_step/1`,
`lib/statifier_persistence/executions.ex`, read at `2e65d8b`). The test
is "inputs/2 refuses" in
`test/statifier_persistence/executions_reentrant_test.exs`. A host that
wants the log of the execution it is stepping reads it after the outer
door has returned, as the Amendment's "The error" paragraph says for any
nested effect.

Nothing in the Amendment moves: the doors, the error and what the rule
leaves alone stay as written, and `inputs/2` called for a different
execution, or from another process, answers as before.

## Note (2026-09-28, sp-2ay1): the Amendment's own "What the rule leaves alone" paragraph, and the refusal ahead of ADR-0017's skips

This Note decides nothing and changes no status line. It extends the
reading the 2026-09-27 sp-4wwq Note gives to one more paragraph, and
says where the dry run's refusal sits against ADR-0017 decision 2's
skips. Every cite was read on `main` at `39bdcb4`, in
`lib/statifier_persistence/executions.ex`.

- **The acceptance Note, by heading.** The line the sp-4wwq Note calls
  the acceptance Note's "What the rule leaves alone" line is the "What
  the rule leaves alone" bullet of "Note (2026-09-27, sp-zwxf):
  the sp-a2ee Amendment is accepted".
- **The Amendment's own paragraph.** The 2026-09-26 Amendment's "What
  the rule leaves alone" paragraph says the doors that take no execution
  id, `migrate_batch/3` among them, check nothing themselves. It is read
  with the sp-4wwq Note, as the acceptance Note's bullet is: the dry run
  of `migrate_batch/3` checks the mark for each execution it lists
  (`batch_one/3`, its `dry_run: true` clause). The rest of the paragraph
  stands: `cascade_cancel/3`, `retire_chart/4` and `executions_on/2` do
  not call `not_in_step/1` (`cascade_cancel/3`, `retire_chart/4`,
  `executions_on/2`), and the apply of `migrate_batch/3` meets the
  refusal through `migrate/4` or `migrate_tree/4` (`apply_one/2`,
  `apply_tree/2`).
- **The sp-4wwq Note's second paragraph** is read as two claims, one
  anchor each: before that Note's change the dry run checked no mark
  (`batch_one/3`, read at `fb277f6`), and since it the check is the
  dry run's first step for each execution (`batch_one/3`, read at
  `39bdcb4`).
- **The refusal comes before decision 2's skips.** The dry run checks
  the mark before it reads the execution (`batch_one/3`), and ADR-0017
  decision 2's `{:skipped, :terminal}` and `{:skipped, :linked}` are
  taken from the record it reads (`preview_skip/1`). The check reads no
  record, so a marked execution answers `{:would_refuse,
  {:reentrant_step, execution_id}}` whatever its status or linkage: an
  execution being stepped that carries a linkage answers that, not
  `{:skipped, :linked}`. The apply answers the same execution
  `{:refused, {:reentrant_step, execution_id}}`, since `migrate_tree/4`
  checks the mark on its root first (`migrate_tree/4`). ADR-0017 carries
  a Note of the same date that reads its own text with this one.

## Note (2026-09-28, sp-nylp): the Amendment's refusal has a second conformance case, under the adapter's own lock

This Note decides nothing and changes no status line. The 2026-09-26
Amendment's "Why here" paragraph says the conformance suite carries one
case for the refusal, and the "The conformance case" bullet of "Note
(2026-09-27, sp-zwxf): the sp-a2ee Amendment is accepted" names the same
one. Both were right when written. Since statifier_persistence 0.22.0
the suite carries a second case, and both passages are read with this
Note. Every cite was read on `main` at `29b9851`.

- **The first case, unchanged.** "facade: a door called from inside its
  own execution's executor refuses, and the outer step is stored"
  (`StatifierPersistence.Testing.StorageConformance`) runs the refusal
  over a serialization strategy that admits its own holder, so no
  adapter's `lock_execution/3` is in its path. It needs no
  `lock_execution/3`, carries no tag and runs for every adapter.
- **The second case.** "adapter: a door called from inside its own
  executor refuses before it reaches lock_execution/3"
  (`StatifierPersistence.Testing.StorageConformance`) runs the same
  refusal through the default strategy, whose `with_execution/3` hands
  the tail to the adapter's own `lock_execution/3`
  (`StatifierPersistence.Serialization.AdapterLock`, `with_execution/3`).
  The nested `step/5` must answer `{:error, {:reentrant_step,
  execution_id}}` while the outer step holds that lock, and the outer
  step's position is the one stored. The outer step runs in a task
  bounded by a timeout, so a lock that waits on its own holder fails the
  case instead of hanging it.
- **Who runs it.** Authors of a storage adapter of their own who run the
  shipped suite against it. The case is generated only when the adapter
  under test exports `lock_execution/3`, beside the two lock cases the
  suite already had, and it carries `@tag :postgres` with them
  (`StatifierPersistence.Testing.StorageConformance`, its moduledoc's
  `lock_execution/3` paragraph). An adapter that does not export the
  callback never sees it.

The Amendment's rule, its error and what it leaves alone are unchanged;
the second case checks the Amendment's own "the refusal comes before any
lock is asked for" against each adapter's lock rather than a stand-in.

## Amendment (2026-09-28, sp-ngnb): the event builder's call is a marked window of the rule

Status of this amendment: accepted (2026-09-28, sp-ngnb). The record
above stays accepted, and so does the 2026-09-26 Amendment.

Pure addition: nothing above is edited. The 2026-09-26 Amendment's rule
marks the execution for the length of each executor call. The
2026-09-27 sp-62q0 Note added a second window to that rule while calling
itself a Note; this Amendment is where the rule records it, and that
Note stays as written and is read with this one.

**The rule, widened.** The execution is marked as in a step in the
calling process for the length of two kinds of call, not one: each
executor call, as the 2026-09-26 Amendment says, and the call that
resolves the event handed to `step/5`, which is where an event builder
of the 2026-09-01 Amendment runs. That second window opens once the
execution's position is loaded and closes when the builder returns,
before any executor call or write of the step; the mark is restored on
every exit from it, as for an executor call. The mark is set around
that call by `step_loaded/8`
(`lib/statifier_persistence/executions.ex`, read at `bcc9f9a`).

**What does not move.** The doors that check the mark, the error they
answer, and what the 2026-09-26 Amendment's "What the rule leaves
alone" paragraph leaves alone (as the later Notes read it) are
unchanged: inside a builder, a door called for a different execution id
proceeds, and a call from another process is not refused. A builder
that calls no door for its own execution, and a caller passing an
`%Event{}`, see no change.

**Shipped.** The code shipped in statifier_persistence 0.22.0 (tag
`v0.22.0`), under a Changed line of its changelog; this Amendment adds no
code.

## Note (2026-09-28, sp-830s): the sp-ngnb Amendment is accepted

The 2026-09-28 sp-ngnb Amendment is accepted on 2026-09-28, under the
operator's standing grant to flip a record whose code has shipped. The
code that implements it shipped in statifier_persistence 0.22.0 (tag
`v0.22.0`, `db26e2f`) under a Changed changelog line. That Amendment's
own status line flips in place from proposed to accepted; the record
above and the 2026-09-26 Amendment stay accepted. Every cite below was
read at `db26e2f`, the tag, and again on `main` at `037f5da`, in
`lib/statifier_persistence/executions.ex` unless another file is named.
Between the two, `lib/` changed only for the retired-hash recheck of
ADR-0012's 2026-09-28 Amendment, which leaves every function cited below
as it was.

What was re-read before the flip:

- **The window.** `step_loaded/8` runs `resolve_event/2`, which calls the
  builder, inside `in_step/2` for the execution being stepped, before
  `stepped/8` runs the executor or writes; `step_tail/7` calls
  `step_loaded/8` only once the position is loaded.
- **The restore.** `in_step/2` restores the mark in an `after` clause, so
  every exit from the builder restores it.
- **What does not move.** `not_in_step/1` answers
  `{:error, {:reentrant_step, execution_id}}` for a marked id only, the
  mark is per process, and a `%Event{}` passes through `resolve_event/2`
  unchanged.
- **The case.** `test/statifier_persistence/executions_reentrant_test.exs`
  carries "a builder calling a door for its own execution is refused".
- **The changelog.** The 0.22.0 section of `CHANGELOG.md` names the
  builder's refusal under Changed.

## Amendment (2026-09-28, sp-xytv): a failed position save after the effects rolls back the executor's writes

Status of this amendment: proposed (2026-09-28, sp-xytv). The record above
stays accepted; this amendment is proposed until its code has shipped in a
published version.

Pure addition: nothing above is edited. Decision 3 orders a step as
execute the effects, then persist, and decision 5 runs that whole tail
inside the execution's serialization strategy. Neither said what becomes
of the executor's writes when the persist that follows them answers an
error. Until this Amendment the Ecto adapter's `lock_execution/3`
(`lib/statifier_persistence/storage/ecto.ex`, read at `0e034dc`) committed
whatever the body returned, an `{:error, _}` included. A step whose
position save answered an error after its executor ran therefore
committed what the executor wrote through the same repo - a host's timer
rows, for one - without the position those rows belong to, which is the
split statifier-ex's ADR-0074 decision 2 asks a timer store to close.

**The decision** (ruled by the operator, 2026-09-28). The executor's
writes and the step's position save are one unit in both directions:
they commit together, and when the save answers an error they are undone
together. When the `:update` write that follows a step's effects answers
an error, the step leaves its serialization strategy by a throw rather
than a return, so the strategy's own exit path runs, and the step still
answers that error, in the same shape as before. The throw is made by
`failed_write/2` and caught by `serialized/5`, which hands the error back
as the step's answer (both in `lib/statifier_persistence/executions.ex`,
added with this Amendment). A redelivery re-drives the whole step: the
effects run again and the save is tried again, which decision 3's
at-least-once property already makes safe.

**What each adapter guarantees.**

- **The Ecto adapter under the default strategy.** `lock_execution/3`
  rolls its transaction back on any exit from its body that is not a
  return, so the executor's writes through the store's repo from the
  calling process, the step's input log entry and anything else the step
  wrote are undone. Inside a caller's own transaction the rollback marks
  that transaction failed, as the 2026-09-23 sp-g7q Note above describes,
  and the caller's transaction ends in `{:error, :rollback}`.
- **The in-memory adapter.** Its `lock_execution/3`
  (`lib/statifier_persistence/storage/in_memory.ex`, read at `0e034dc`)
  takes a lock and no transaction. The throw releases the lock and undoes
  nothing: what the step wrote before the failed save stays.
- **A host's own strategy.** The throw passes through its body. What it
  undoes on that exit is the strategy's own; the
  `c:StatifierPersistence.Serialization.with_execution/3` doc says so.

The conformance case "adapter: lock_execution/3 releases the lock after a
raising or throwing fun" (`StatifierPersistence.Testing.StorageConformance`)
pins what every adapter owes: the throw reaches the caller as thrown and
the lock is released.

**What does not roll back.** Only a failed save after the effects does.
These keep committing, as before:

- A budget-exhausted step. `tail_result/6` answers
  `{:error, {:budget_exhausted, payload}}` after the `:failed` record is
  written (decision 1), so that record and the executor's writes commit.
- `StatifierPersistence.Driver`'s record-then-settle. `record_and_settle/5`
  (`lib/statifier_persistence/driver.ex`, read at `0e034dc`) records a
  child's outcome and may then answer a settlement error; it is not a
  step's tail and commits what it wrote.
- A create whose insert is refused. It answers as before. On Postgres the
  failed `INSERT` has already aborted the transaction it ran in (the
  README's "Writing inside a caller's transaction"), so nothing it wrote
  commits either way.
- A refusal or discard before the effects. Nothing has been executed.

**The input log entry goes with the step.** ADR-0010 appends only inputs
the interpreter saw, as a replay log of the execution that happened. An
entry kept for a step whose position was never saved would replay a step
that did not happen, and the redelivery appends the event again.

**Pinned.** `test/statifier_persistence/ecto/step_timer_store_transaction_test.exs`
carries "a step whose position save answers an error rolls back the
executor's timer writes" and "a budget-exhausted step still commits its
:failed record and its executor's writes", against real Postgres. The
changelog names the change under Changed.
