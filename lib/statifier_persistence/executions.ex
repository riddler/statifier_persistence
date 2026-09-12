defmodule StatifierPersistence.Executions do
  @moduledoc """
  The execution lifecycle: create and step durable executions with no live Session
  process, the loop this package exists to package.

  A step runs in ADR-0004 decision 3's order, and the order is the
  contract: liveness check on the execution record -> load (guarded) -> re-stamp
  `routes`/`invoke_types` unconditionally (with the nil tripwire from
  st-ADR-0064: the fields are pattern-matched `nil` before stamping, so an
  upstream regression fails loudly here, not silently downstream) -> step
  via `Interpreter.handle_event/2` -> execute effects via the executor
  seam -> consume `:done` and `:budget_exhausted` into execution status -> assert
  `MachineState.internal_queue_empty?/1` -> persist.

  Effect execution is at-least-once: a crash between step and persist
  re-drives the same event and re-emits the same effects with identical
  deterministic keys (st-ADR-0054 decision 3, st-ADR-0059), and this loop
  never dedupes - idempotency is the consumer's. `:done` is the only path
  to `:completed` (ADR-0004 decision 6); an event delivered to a terminal
  execution is discarded with a typed `{:discarded, execution}` result, never an
  exception and never a silent step.

  ## A chart says its own execution failed

  Two routes reach `:failed`, and both are the chart's own word rather than
  the host's - `fail/4` is the host-driven one (ADR-0004 decision 6).

  The first is macrostep-budget exhaustion, which also returns
  `{:error, {:budget_exhausted, payload}}` after the record is durable.

  The second (ADR-0008's 2026-09-06 amendment) is a **failure-classed
  final**: a top-level `<final>` whose `<donedata>` carries the reserved
  key `statifier_persistence:execution_status` with the value `"failed"`.

      <final id="ended_badly">
        <donedata>
          <param name="statifier_persistence:execution_status" expr="'failed'"/>
        </donedata>
      </final>

  Settling there is an ordinary successful step - it returns
  `{:ok, %StatifierPersistence.Execution{status: :failed}, machine_state}`, not
  the budget route's error tuple, because a chart that says it failed has
  not malfunctioned, it has finished. The execution's `failure` string is
  `"failed_final"`, the same string the
  `[:statifier_persistence, :execution, :terminated]` event reports as `reason`
  and `StatifierPersistence.Driver` sends a durable parent as
  `{:failed, reason: ...}`, so a `:first_error` fan-out cancels the failed
  child's siblings through the cascade ADR-0008 decision 5 already built.
  The resolved `<donedata>` reaches the parent verbatim, tag included -
  nothing is stripped.

  The value set is closed at `"failed"`: any other value is ignored and the
  execution takes the status it would have taken with no key at all, so a chart
  cannot claim a `:completed` it did not reach or a `:cancelled` that is
  the parent's word. An unhandled `error.communication` or
  `error.execution` is **not** a route: a chart that raises an error it
  does not catch stays `:active`, which is a chart bug its author fixes
  with a transition to a failure-classed final, not a status this package
  infers on the author's behalf (amendment decision 4).

  Before 0.12.0 the reserved key was spelled
  `statifier_persistence:run_status`. That spelling is still **read** in
  0.12.0 and is dropped in 0.13.0 (ADR-0011 decision 4): where both keys are
  present the new one wins, and reading the old one logs one deprecation line
  at `:debug` naming the new key.

  Executor failures on actionable effects re-enter the chart as
  `error.communication` events through `Statifier.Interpreter.deliver_internal/5`
  (st-ADR-0039's seam), per st-ADR-0051's failed-communication row: the core
  alone mints the planning-time execution-error events, before any effect is
  emitted, so every failure an executor can report re-enters uniformly as
  `error.communication` (ADR-0004
  decision 4). Failures on observational effects are discarded. Re-entry is
  single-wave per step: effects the re-entries emit are executed too, but
  their failures are not re-entered again, so a deterministically failing
  executor cannot loop this library.

  Concurrent deliveries to one execution are ordered by a pluggable per-execution
  serialization strategy (ADR-0004 decision 5): every entry point executions its
  fetch-to-persist tail inside the strategy's
  `c:StatifierPersistence.Serialization.with_execution/3`, selected per call with
  `serialization: {module, config}` and defaulting to
  `{StatifierPersistence.Serialization.AdapterLock, store}` - the adapter's
  own optional `lock_execution/3`. A strategy refusal surfaces unchanged as
  `{:error, {:serialization, reason}}`.
  """

  require Logger

  alias Statifier.{Event, Interpreter, Machine, MachineState}

  alias Statifier.Effect.{
    Autoforward,
    BudgetExhausted,
    Cancel,
    CancelInvoke,
    Done,
    Invoke,
    Send,
    SendDelayed
  }

  alias Statifier.Machine.Identity

  # Family one's emitter (ADR-0009 decision 2), aliased rather than wrapped:
  # `Telemetry` in this module is this package's own family-two module, and
  # `st-ADR-0067` decision 2 exists precisely so this package calls the same
  # functions `Statifier.Session` calls instead of standing up a second
  # implementation of a 27-name contract.
  alias Statifier.Telemetry, as: CoreTelemetry

  alias StatifierPersistence.{Driver, Execution, Executor, Storage, Telemetry}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage.Adapter

  @typedoc "An execution's caller-supplied opaque key (ADR-0004 decision 2)."
  @type execution_id :: Adapter.execution_id()

  # The `driver` metadatum on every family-one event this module emits
  # (`st-ADR-0067` decision 4 left the atom to this repository; ADR-0009
  # decision 2 fixed it and froze it). Changing it is a breaking change to
  # a real consumer, not an amendment.
  @driver :persistence

  # A family-one macrostep span in flight: the `System.monotonic_time/0`
  # reading the stop half measures `duration` against, and the
  # `make_ref/0` that pairs the two halves (`st-ADR-0040` decision 2's
  # semantics, kept verbatim). `nil` where no span was opened.
  @typep span :: {integer(), reference()} | nil

  # The `step_reporter:` option's fun, threaded to the persist tail and
  # called there with the step's whole effect list. `nil` - the ordinary
  # case, every caller but a `Driver` carrying an `after_step:` - reports
  # nothing.
  @typep step_reporter :: ([Statifier.Effect.t()] -> any()) | nil

  # The persist tail's executor seam, carried as one term so the
  # effect-execution functions take a `context` and its telemetry
  # companion together rather than four positional arguments.
  #
  # `context` is the host-facing `t:StatifierPersistence.Executor.context/0`
  # and is passed to the executor unchanged; `session_id` never reaches the
  # executor - it rides `[:statifier_persistence, :effect, :failed]` alone,
  # because adding a key to the executor's context would be a change to
  # ADR-0004 decision 4's contract rather than to this package's telemetry.
  @typep seam :: %{
           context: Executor.context(),
           executor: Executor.t(),
           session_id: String.t() | nil
         }

  @typedoc """
  An event `step/5` can only build once the execution's position is loaded.

  Called with the loaded, re-stamped `t:Statifier.MachineState.t/0`, inside
  the serialization strategy's `with_execution/3` and before
  `Statifier.Interpreter.handle_event/2` - so what it reads and what the
  step acts on are the same position under the same exclusion. `{:ok,
  event}` steps that event; `:discard` steps nothing and returns
  `{:discarded, execution}`.

  It exists for events whose *right to be delivered at all* is a property
  of the position: an invocation's late answer, which spec 6.4.3 discards
  when the invocation is no longer live (`StatifierPersistence.Driver`'s
  `done_invocation/5`). This adds no step to ADR-0004 decision 3's order -
  the event argument is late-bound, the loop is not re-ordered.
  """
  @type event_builder :: (MachineState.t() -> {:ok, Event.t()} | :discard)

  @typedoc """
  This module's error vocabulary: the facade's arms, unflattened, plus the
  `{:budget_exhausted, payload}` arm returned after a budget-exhausted step
  or create has persisted its `:failed` execution record, plus the serialization
  strategy's own refusal, surfaced unchanged
  (`{:serialization, :not_supported}` from the default strategy over an
  adapter with no `lock_execution/3`).
  """
  @type error ::
          Storage.error()
          | {:budget_exhausted, BudgetExhausted.t()}
          | {:serialization, term()}

  @typedoc """
  Options `create/4` and `step/5` accept:

  - `executor:` (required) - the `t:StatifierPersistence.Executor.t/0`
    every non-lifecycle effect is handed to, in list order.
  - `routes:` - the `t:Statifier.Send.Routes.t/0` snapshot stamped onto the
    loaded position before the step; host-supplied per call, never read
    back from storage (st-ADR-0048). Defaults to `nil`, "no determination
    made".
  - `invoke_types:` - the `t:Statifier.Invoke.Types.t/0` snapshot, stamped
    the same way (st-ADR-0051). Defaults to `nil`, "the built-in set only".
  - `initialize:` (`create/4` only) - passed to
    `Statifier.Interpreter.initialize/2` unchanged.
  - `metadata:` (`create/4` only) - the optional opaque map of host
    identities stored beside the execution record (ADR-0006 decision 1),
    defaulting to `%{}`. Identities only, never personal data (decision 2);
    an adapter that cannot store a non-empty map refuses the create with
    `{:error, :metadata_unsupported}` (decision 3).
  - `serialization:` - the `{module, config}` per-execution serialization
    strategy the fetch-to-persist tail runs inside (ADR-0004 decision 5;
    `fail/4` accepts it too). Defaults to
    `{StatifierPersistence.Serialization.AdapterLock, store}`.
  - `entry:` - this package's own, never a host's: the public door this
    drive came through, carried on
    `[:statifier_persistence, :execution, :step, :start | :stop]` and
    `[:statifier_persistence, :execution, :discarded]` as `entry` (ADR-0009,
    `docs/telemetry.md`). `StatifierPersistence.Driver` sets it to
    `:done_invocation`, `:failed_invocation` or `:answer_parent` on the
    doors that reach `step/5` rather than being one of its own; every
    other entry point derives its own (`:create`, `:step`, `:fail`,
    `:cancel`). It stopped being telemetry-only with ADR-0010: on an
    adapter that keeps an input log, `entry:` also stamps the stored
    entry's `door` (decision 5). It changes nothing else.
  - `linkage:` (`create/4` only) - this package's own, never a host's. Set
    by the durable subchart `start_child` clause (Phase 3) to record a
    child's parent under the reserved metadata namespace
    (`StatifierPersistence.Execution.Linkage`, ADR-0008 decision 2). A host
    supplies `metadata:` for its own identities; supplying `linkage:` from
    outside this package is a caller bug the same way a malformed
    `metadata:` is.
  - `invoke_id:` and `child_count:` - this package's own, never a host's,
    and telemetry only. Set by `StatifierPersistence.Driver` beside
    `entry: :answer_parent`, they name the invocation the step is
    answering and its width on
    `[:statifier_persistence, :execution, :step, :stop]` (the ADR-0009 sp-8wv
    amendment). `child_count` is `nil` for a single-child subchart. They
    change nothing else about the step.
  - `step_reporter:` - this package's own, never a host's, and the seam
    ADR-0008's `after_step:` amendment (2026-09-08) needed: a 1-arity fun
    this call hands the step's WHOLE effect list to - the list this
    module's persist tail is handed, before it splits the lifecycle
    effects off - once the persist has landed and before the entry point
    returns. Set by `StatifierPersistence.Driver` when, and only when,
    its own `after_step:` is set, and set to a fun that *records* the
    list rather than acting on it: the driver fires the host's callback
    itself, after this function has returned and outside the execution's own
    exclusion (the amendment's clause 3). It is a reporter and not the
    callback because the amendment rules out widening this module's
    public returns to carry the list, and because nothing a host wrote
    should run inside a serialized section this package opened. Its
    return value is discarded and it changes nothing about the step.
  """
  @type opt ::
          {:executor, Executor.t()}
          | {:routes, MachineState.routes()}
          | {:invoke_types, MachineState.invoke_types()}
          | {:initialize, keyword()}
          | {:serialization, {module(), term()}}
          | {:metadata, Adapter.metadata()}
          | {:linkage, Linkage.t()}
          | {:entry, entry()}
          | {:invoke_id, String.t()}
          | {:child_count, pos_integer()}
          | {:step_reporter, ([Statifier.Effect.t()] -> any())}

  @typedoc """
  The fixed vocabulary of public doors `entry` names on this package's own
  telemetry (`docs/telemetry.md`). It is the dimension an operator slices
  step latency by first, because a `:done_invocation` step and a `:step`
  step have different expected shapes.

  It is also ADR-0010's door vocabulary: the same seven atoms, stored as
  strings on an input log entry, and the record adds no second one. Of the
  seven, only `:step`, `:done_invocation` and `:failed_invocation` -
  `:answer_parent` among them, since it re-enters the parent through one
  of the two invocation doors - ever carry an event into an interpreter,
  so those are the doors that append (decision 5's table).
  """
  @type entry ::
          :create
          | :step
          | :done_invocation
          | :failed_invocation
          | :answer_parent
          | :fail
          | :cancel

  @doc """
  Creates an execution: `Statifier.Interpreter.initialize/2` (which cannot fail),
  then the shared persist tail - effects through the executor seam,
  `:done`/`:budget_exhausted` consumed into execution status, quiescence
  asserted, the record inserted with its encoded position.

  Create-exactly-once rests on the adapter's atomic `:execution_exists` refusal
  (ADR-0004 decision 2), not on a pre-check here: creating an existing
  `execution_id` returns `{:error, :execution_exists}`.

  A create whose `initialize/2` exhausts its macrostep budget persists a
  `:failed` execution with no position blob (there is no quiescent position to
  store - ADR-0004 decision 1) and then returns
  `{:error, {:budget_exhausted, payload}}`, so the caller sees both the
  durable state and the reason.

  `metadata:` rides through to the inserted execution record unchanged (ADR-0006
  decision 1). Create is the only place it is set - `step/5` and `fail/4`
  carry the stored map forward and take no `metadata:` of their own - and
  an adapter that cannot store a non-empty map refuses here, before any
  effect is executed: `{:error, :metadata_unsupported}`.
  """
  @spec create(
          store :: Storage.t(),
          execution_id :: execution_id(),
          machine :: Machine.t(),
          opts :: [opt()]
        ) ::
          {:ok, Execution.t(), MachineState.t()} | {:error, error()}
  def create(%Storage{} = store, execution_id, %Machine{} = machine, opts) do
    executor = Keyword.fetch!(opts, :executor)

    # ADR-0006 decision 3's refusal is at open, and "at open" has to mean
    # before initialize/2's effects reach the executor: a create the
    # adapter will refuse must not fire an effect on its way to the
    # refusal, for the same reason the identity refusal runs first below.
    #
    # Only the `metadata:` pair crosses, never the whole list (sp-3kk).
    # `check_metadata/2`'s contract is `[Storage.execution_write_opt()]` -
    # `:failure`/`:metadata`/`:position` - and this list is `[opt()]`,
    # whose REQUIRED `executor:` is not a member of it. Handing the whole
    # list over made dialyzer intersect the two: the success typing it
    # derived for `create/4` accepted no `executor:` at all, so every
    # correct call was reported as one that will never return, and the
    # first production embedder had to suppress the finding on a wrapper
    # function. `Keyword.take/2` passes exactly what the callee reads.
    #
    # The refusal-at-open check has to see the *merged* map (the host's
    # `metadata:` plus a Phase 3 `linkage:`), not just the host's, so the
    # merge happens first and `check_metadata/2` is handed the result as
    # its own `:metadata` pair - a durable child on a metadata-less adapter
    # is refused before any effect executions, the same ordering ADR-0006
    # decision 3 set for a host's own metadata.
    metadata = metadata(opts)

    with :ok <- Storage.check_metadata(store, metadata: metadata) do
      # Read before the advance so the `:initialize` span's `duration`
      # measures the core call alone, even though both halves are emitted
      # after it (`report_initialized/4` says why).
      span_start = System.monotonic_time()

      {machine_state, effects} =
        Interpreter.initialize(machine, Keyword.get(opts, :initialize, []))

      report_initialized(machine, machine_state, effects, span_start)

      reporter = Keyword.get(opts, :step_reporter)

      serialized(store, execution_id, :create, opts, fn ->
        persist_tail(
          store,
          execution_id,
          machine_state,
          effects,
          executor,
          {:insert, metadata},
          reporter
        )
      end)
    end
  end

  # A host writing into the reserved namespace collides with the package
  # (ADR-0008, Consequences). The shape of `metadata:` is the one thing
  # ADR-0006 decision 1 validates and a malformed option is a caller bug,
  # so this raises rather than joining the error vocabulary - same posture
  # as `Storage.metadata_opt!/1`.
  #
  # A non-map `:metadata` is left untouched here rather than inspected:
  # `Map.has_key?/2` on a non-map raises `BadMapError`, the wrong exception
  # for the wrong reason, and `check_metadata/2`'s own `metadata_opt!/1`
  # already raises the right `ArgumentError` for that shape downstream -
  # this function's job is only the reserved-key guard and the `linkage:`
  # merge, both of which need an actual map to mean anything.
  @spec metadata([opt()]) :: Adapter.metadata()
  defp metadata(opts) do
    case Keyword.get(opts, :metadata, %{}) do
      supplied when is_map(supplied) ->
        if Map.has_key?(supplied, Linkage.reserved_key()) do
          raise ArgumentError,
                "the #{inspect(Linkage.reserved_key())} metadata key is reserved by " <>
                  "statifier_persistence for durable subchart linkage (ADR-0008 " <>
                  "decision 2) and cannot be supplied by a host"
        end

        case Keyword.get(opts, :linkage) do
          nil -> supplied
          %Linkage{} = linkage -> Map.merge(supplied, Linkage.to_metadata(linkage))
        end

      malformed ->
        malformed
    end
  end

  @doc """
  Delivers one external event to an execution, in ADR-0004 decision 3's order (the
  moduledoc quotes it).

  An event delivered to a terminal execution returns `{:discarded, execution}` from the
  execution record alone, before any position decode. `handle_event/2`'s
  `{:error, :not_running}` arm is the structural backstop for an execution record
  whose `:active` status lies about a terminal stored position: it discards
  too, and repairs the record's status to `:completed` on the way out.

  `event` may also be a `t:event_builder/0` - a fun the loaded position is
  handed, for an event only the position can build or decline. A builder
  that declines discards the delivery through the same `{:discarded, execution}`
  arm.
  """
  @spec step(
          store :: Storage.t(),
          execution_id :: execution_id(),
          machine :: Machine.t(),
          event :: Event.t() | event_builder(),
          opts :: [opt()]
        ) ::
          {:ok, Execution.t(), MachineState.t()} | {:discarded, Execution.t()} | {:error, error()}
  def step(%Storage{} = store, execution_id, %Machine{} = machine, event, opts)
      when is_struct(event, Event) or is_function(event, 1) do
    executor = Keyword.fetch!(opts, :executor)
    entry = entry(opts, :step)

    serialized(store, execution_id, entry, opts, fn ->
      step_tail(store, execution_id, machine, event, opts, executor, entry)
    end)
  end

  @spec step_tail(
          Storage.t(),
          execution_id(),
          Machine.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t(),
          entry()
        ) ::
          {:ok, Execution.t(), MachineState.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp step_tail(store, execution_id, machine, event, opts, executor, entry) do
    case Storage.fetch_execution(store, execution_id) do
      {:ok, %{status: status} = execution_record}
      when status in [:completed, :failed, :cancelled] ->
        discarded(execution_record, execution_id, entry, :terminal_execution)

      {:ok, execution_record} ->
        with {:ok, machine_state} <- Storage.load_execution_position(store, execution_id, machine) do
          step_loaded(
            store,
            execution_id,
            execution_record,
            machine_state,
            event,
            opts,
            executor,
            entry
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Abandons an execution: the only host-driven terminal transition (ADR-0004
  decision 6). No interpreter is involved - abandonment is a host decision
  about the execution, not a chart transition - so the stored position is left
  untouched and only the record's status and failure reason change.

  A terminal execution is discarded, same as `step/5`: `{:discarded, execution}`.
  `reason` is the short string stored as the execution's `failure` - keep it a
  prefixed, console-readable reason, not an inspect dump.

  `opts` accepts `serialization:` - the same `{module, config}` strategy
  `create/4` and `step/5` take, with the same default - and `driver:`.

  ## `driver:` and a linked child (ADR-0008's outside-fail note)

  An execution failed here is failed from *outside* the interpreter, so nothing in
  this call steps a chart and nothing in it reaches the parent of a durable
  subchart child (ADR-0008 decision 2's linkage). Left there, a child a
  host abandons this way holds its parent's `<invoke>` `:pending` forever:
  every path that answers a parent hangs off a drive of the child, and an
  outside fail is the one terminal transition that has no drive.

  `driver:` is that answer. Given a `t:StatifierPersistence.Driver.t/0`,
  an execution that carried linkage and actually reached `:failed` here answers
  its parent with `{:failed, reason: reason}` - the ADR-0008 spelling, the
  same payload the automatic path builds from an execution's stored `failure` -
  through `StatifierPersistence.Driver.resolve_and_answer_parent/3`, the
  same write site the stepped path uses. A fan-out child settles rather
  than answering, because that routing lives in
  `StatifierPersistence.Driver.answer_parent/3` and both paths reach it.

  The driver must be able to answer the parent: either its
  `chart_resolver:` resolves the parent's chart, or its `machine` already
  *is* the parent's chart. Its `store` is what the answer reads and writes
  through, so it is normally a driver over this same store.

  Two boundaries this option does not cross. The answer happens **after**
  this execution's own serialization section commits, not inside it - the same
  order `create/3` and `send_event/4` answer in, and the reason a nested
  exclusion is never taken here. And the answer's own outcome does not
  change this function's: a parent that has already cancelled the
  invocation, or that cannot be resolved, leaves `{:ok, execution}` exactly as it
  is. What that window costs, and what closes it, is
  `docs/adr/0008-durable-subchart-child-executions.md`'s note.

  Without `driver:` nothing about this call changes, for a linked execution or an
  unlinked one: no linkage is read and no parent is answered.
  """
  @spec fail(
          store :: Storage.t(),
          execution_id :: execution_id(),
          reason :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()}
  def fail(%Storage{} = store, execution_id, reason, opts \\ []) when is_binary(reason) do
    store
    |> serialized(execution_id, :fail, opts, fn -> fail_tail(store, execution_id, reason) end)
    |> answer_parent_of_failed(execution_id, reason, opts)
  end

  # The answer is deliberately outside `serialized/5` above: it takes the
  # *parent's* exclusion, and taking it from inside the child's would nest
  # two execution locks in an order nothing else in this package takes them in.
  # `create/3` and `send_event/4` answer in this same order - after their
  # own drive returns - so the outside fail's window is the stepped path's
  # window and not a new one.
  @spec answer_parent_of_failed(
          {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()},
          execution_id(),
          String.t(),
          keyword()
        ) :: {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp answer_parent_of_failed(
         {:ok, %Execution{status: :failed}} = result,
         execution_id,
         reason,
         opts
       ) do
    case Keyword.get(opts, :driver) do
      nil ->
        result

      driver ->
        Driver.resolve_and_answer_parent(driver, execution_id, {:failed, reason: reason})

        result
    end
  end

  defp answer_parent_of_failed(result, _execution_id, _reason, _opts), do: result

  @spec fail_tail(Storage.t(), execution_id(), String.t()) ::
          {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp fail_tail(store, execution_id, reason) do
    case Storage.fetch_execution(store, execution_id) do
      {:ok, %{status: status} = execution_record}
      when status in [:completed, :failed, :cancelled] ->
        discarded(execution_record, execution_id, :fail, :terminal_execution)

      {:ok, execution_record} ->
        with :ok <- Storage.update_execution_status(store, execution_id, :failed, failure: reason) do
          terminated(execution_id, execution_record.content_hash, :failed, reason)
          {:ok, Execution.from_record(%{execution_record | status: :failed, failure: reason})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancels an execution: the second host-driven terminal transition (ADR-0004
  decision 6 as extended by ADR-0008 decision 5), and the one a cascading
  cancel writes through.

  Cancellation **retains**: no record and no position is deleted, no
  interpreter is involved, and the stored position is left untouched - only
  the record's status changes, to `:cancelled`. An execution that is already
  terminal - cancelled by an earlier, interrupted cascade included - is
  discarded with `{:discarded, execution}`, which is what makes re-running a
  cascade over an already-cancelled subtree a no-op.

  `opts` accepts `serialization:` only - `fail/4`'s `serialization:`,
  without its `driver:`: no chart is stepped by a cancel, on either side of
  a linkage.
  """
  @spec cancel(store :: Storage.t(), execution_id :: execution_id(), opts :: keyword()) ::
          {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()}
  def cancel(%Storage{} = store, execution_id, opts \\ []) do
    serialized(store, execution_id, :cancel, opts, fn -> cancel_tail(store, execution_id) end)
  end

  @spec cancel_tail(Storage.t(), execution_id()) ::
          {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp cancel_tail(store, execution_id) do
    case Storage.fetch_execution(store, execution_id) do
      {:ok, %{status: status} = execution_record}
      when status in [:completed, :failed, :cancelled] ->
        discarded(execution_record, execution_id, :cancel, :terminal_execution)

      {:ok, execution_record} ->
        with :ok <- Storage.update_execution_status(store, execution_id, :cancelled, failure: nil) do
          terminated(execution_id, execution_record.content_hash, :cancelled, nil)
          {:ok, Execution.from_record(%{execution_record | status: :cancelled, failure: nil})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancels every execution linked to `parent_execution_id` - for one invocation, or for
  all of them - and every execution linked to those, recursively (ADR-0008
  decision 5).

  Retains: nothing is deleted and every position is left byte-identical;
  each execution simply takes the `:cancelled` terminal status through `cancel/3`.

  Idempotent, and idempotent in the strong sense a crash needs. The walk
  descends into every child it finds, whatever that child's own status, and
  `cancel/3` discards an execution that is already terminal - so a cascade
  interrupted halfway through a deep tree is completed correctly by
  re-running it, and a cascade over a subtree that is already fully
  cancelled writes nothing at all.

  There is no global transaction and there deliberately is none: each
  execution's cancel is its own serialized write under its own execution's exclusion
  (ADR-0004 decision 5), so a deep tree is O(subtree) writes. Cross-execution
  locking is the only way to make it atomic, and this package does not have
  it and does not want it.

  Termination rests on the execution tree being acyclic, which it is by
  construction: a child's execution id strictly extends its parent's
  (`StatifierPersistence.Execution.Linkage.child_execution_id/3`), so no execution can be its
  own descendant. This is why no depth ceiling is needed (ADR-0008
  decision 6).

  That same fact is what makes the lock order safe, which is worth stating
  because this walk is the one place a cycle would be conceivable. It executions
  from inside the caller's own exclusion on every path that has one - the
  `{:cancel_invoke, _}` effect fires inside the exiting execution's, and
  `first_error`'s settlement fires it inside the PARENT's - and it only
  ever takes an exclusion on an execution further down that same subtree. Nothing
  here holds a descendant's exclusion and then asks for an ancestor's: a
  child releases its own before answering its parent
  (`Driver.maybe_answer_parent/3` runs after the drive returns), and the
  parent's door is stepped after the settlement's exclusion closes rather
  than inside it. So the wait-for relation between two connections embeds
  in the execution tree, and an acyclic tree has no cycle to deadlock on.
  `test/statifier_persistence/driver_fanout_test.exs` pins the direction;
  its Ecto variant runs it against real Postgres advisory locks.

  `metadata_match` is a `StatifierPersistence.Execution.Linkage` containment map -
  `Linkage.invocation_match/2` to cancel one invocation's subtree,
  `Linkage.parent_match/1` for every child a parent has ever started. `opts`
  accepts `serialization:` only, threaded to every `cancel/3` call the walk
  makes, exactly as `cancel/3` itself accepts it.
  """
  @spec cascade_cancel(
          store :: Storage.t(),
          metadata_match :: Adapter.metadata(),
          opts :: keyword()
        ) ::
          {:ok, non_neg_integer()} | {:error, error()}
  def cascade_cancel(%Storage{} = store, metadata_match, opts \\ []) do
    case sweep(store, metadata_match, opts) do
      {:ok, {cancelled, retained}} ->
        emit_cascade(metadata_match, cancelled, retained)
        {:ok, cancelled}

      {:error, _reason} = error ->
        error
    end
  end

  # The recursive half. It is separate from the public function for one
  # reason: `[:statifier_persistence, :child, :cascade_cancelled]` reports
  # the whole sweep once (ADR-0009 decision 3's fourth bullet), and a
  # recursion through the public door would emit one event per node of the
  # tree instead. The `retained` half of the tally is ADR-0008 decision
  # 5's retain semantics as a number: the executions the walk found already
  # terminal and left alone.
  @spec sweep(Storage.t(), Adapter.metadata(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp sweep(store, metadata_match, opts) do
    with {:ok, records} <- Storage.list_executions_by_metadata(store, metadata_match) do
      Enum.reduce_while(records, {:ok, {0, 0}}, &cascade_step(store, &1, opts, &2))
    end
  end

  @doc """
  Lists `execution_id`'s input log, in the order the execution's interpreter saw it
  (ADR-0010 decision 2).

  Each entry carries its ordinal (`seq`, dense from zero), the public
  door it entered by, and the `%Statifier.Event{}` itself - equal to the
  one that was delivered, `caller_context` and all. An entry whose
  `event` is `nil` is the closed marker a host-declared cap wrote
  (decision 6); a reader mapping this log onto a replay refuses on it
  rather than replaying an execution that never happened.

  `:not_supported` for a store whose adapter keeps no log - which is not
  a failure, since nothing in this package refuses an execution over it
  (decision 1). `{:error, :execution_not_found}` for an execution that does not exist,
  and `{:ok, []}` for one that has taken no input yet.

  Read-only and outside the execution's exclusion by design: this is a
  diagnostic read, and nothing in this package consumes it. The replay
  itself is `StatifierUI.Trace.Replay.from_events/4`'s, under the mapping
  ADR-0010 decision 8 names and no code here builds.
  """
  @spec inputs(store :: Storage.t(), execution_id :: execution_id()) ::
          {:ok, [Storage.input()]} | :not_supported | {:error, error()}
  def inputs(%Storage{} = store, execution_id) when is_binary(execution_id),
    do: Storage.list_inputs(store, execution_id)

  # The match map is this package's own (`Execution.Linkage.parent_match/1` or
  # `invocation_match/2`), so reading the two ids back out of it is
  # reading what this package just wrote. `invoke_id` is `nil` for the
  # whole-parent sweep, which is the contract's own value for it.
  @spec emit_cascade(Adapter.metadata(), non_neg_integer(), non_neg_integer()) :: :ok
  defp emit_cascade(metadata_match, cancelled, retained) do
    linkage = Map.get(metadata_match, Linkage.reserved_key(), %{})

    Telemetry.child_cascade_cancelled(cancelled, retained,
      parent_execution_id: Map.get(linkage, "parent_execution_id"),
      invoke_id: Map.get(linkage, "invoke_id")
    )
  end

  @spec cascade_step(
          Storage.t(),
          Adapter.execution_record(),
          keyword(),
          {:ok, {non_neg_integer(), non_neg_integer()}}
        ) ::
          {:cont, {:ok, {non_neg_integer(), non_neg_integer()}}} | {:halt, {:error, error()}}
  defp cascade_step(store, record, opts, {:ok, {cancelled, retained}}) do
    case cancel_and_descend(store, record.execution_id, opts) do
      {:ok, {node_cancelled, node_retained}} ->
        {:cont, {:ok, {cancelled + node_cancelled, retained + node_retained}}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  # The child is cancelled *before* the walk into its own children (the
  # moduledoc's ordering note): an interrupted cascade always leaves the
  # deepest still-active executions reachable from an execution that is already
  # cancelled, which a re-execution finds because the walk descends through
  # cancelled executions too - `cancel/3`'s own discard for an already-terminal
  # execution stops nothing here, it only stops that one execution's own count.
  @spec cancel_and_descend(Storage.t(), execution_id(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp cancel_and_descend(store, execution_id, opts) do
    with {:ok, {cancelled, retained}} <- cancel_counted(store, execution_id, opts),
         {:ok, {sub_cancelled, sub_retained}} <-
           sweep(store, Linkage.parent_match(execution_id), opts) do
      {:ok, {cancelled + sub_cancelled, retained + sub_retained}}
    end
  end

  @spec cancel_counted(Storage.t(), execution_id(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp cancel_counted(store, execution_id, opts) do
    case cancel(store, execution_id, opts) do
      {:ok, _execution} -> {:ok, {1, 0}}
      {:discarded, _execution} -> {:ok, {0, 1}}
      {:error, _reason} = error -> error
    end
  end

  # Executions `fun` - one entry point's whole fetch-to-persist tail - inside the
  # selected serialization strategy's `with_execution/3` (ADR-0004 decision 5),
  # unwrapping the strategy's `{:ok, result}` envelope back to the tail's
  # own result. A strategy refusal (`{:error, {:serialization, _}}` from
  # the default over an adapter with no `lock_execution/3`) surfaces unchanged.
  # Nothing inside any tail calls back into this function, so `with_execution/3`
  # never nests on one execution id.
  #
  # This is also the step seam (ADR-0009 decision 5): the one `:start` /
  # `:stop` pair this package emits brackets exactly this function, so the
  # upstream macrostep span - opened inside `fun` - nests inside it by
  # ordinary ambient context, and `st-ADR-0067` decision 5's "a span never
  # crosses a persist boundary" holds structurally rather than by
  # discipline. `[:statifier_persistence, :execution, :lock]`'s `duration` is
  # the *wait*, which is why it is measured from before `with_execution/3` to
  # the first line inside the body it runs rather than around the call:
  # the held time is the step, and the step already has a span.
  @spec serialized(Storage.t(), execution_id(), entry(), keyword(), (-> result)) ::
          result | {:error, error()}
        when result: term()
  defp serialized(store, execution_id, entry, opts, fun) do
    {strategy, config} = Keyword.get(opts, :serialization, {AdapterLock, store})
    span_ref = make_ref()
    started_at = Telemetry.execution_step_start(execution_id, entry, span_ref)
    lock_start = System.monotonic_time()

    locked =
      strategy.with_execution(config, execution_id, fn ->
        emit_lock(lock_start, execution_id, strategy, :acquired, nil)
        fun.()
      end)

    result = unlocked(locked, lock_start, execution_id, strategy)

    Telemetry.execution_step_stop(
      started_at,
      step_stop_fields(execution_id, entry, span_ref, result, opts)
    )

    result
  end

  @spec unlocked({:ok, result} | {:error, term()}, integer(), execution_id(), module()) ::
          result | {:error, error()}
        when result: term()
  defp unlocked({:ok, result}, _lock_start, _execution_id, _strategy), do: result

  defp unlocked({:error, reason} = error, lock_start, execution_id, strategy) do
    emit_lock(lock_start, execution_id, strategy, :unavailable, reason)
    error
  end

  @spec emit_lock(integer(), execution_id(), module(), :acquired | :unavailable, term()) :: :ok
  defp emit_lock(lock_start, execution_id, strategy, outcome, reason) do
    Telemetry.execution_lock(System.monotonic_time() - lock_start,
      execution_id: execution_id,
      strategy: strategy,
      outcome: outcome,
      reason: reason
    )
  end

  # The stop half's metadata, read off whichever of the four return shapes
  # the tail produced. `session_id` is `nil` wherever no position was
  # decoded (ADR-0009 decision 4's honest nil): a terminal-execution discard
  # reads the execution record only, and a lock or identity refusal never loads
  # at all. `status` is `nil` where the step reached no write - with the
  # one exception of `{:budget_exhausted, _}`, which reaches a `:failed`
  # write and *then* returns an error (`tail_result/5`).
  #
  # `invoke_id` and `child_count` are the settlement dimensions (sp-8wv's
  # ADR-0009 amendment): `nil` on every ordinary drive, and set by
  # `StatifierPersistence.Driver` on the `entry: :answer_parent` step it
  # takes on a parent's behalf, so the step span that carries a fan-out's
  # whole assembled answer is recognisable as one. They are metadata
  # rather than measurements because they are dimensions of the span, not
  # quantities it measured, and `child_count` is `nil` for a single-child
  # subchart.
  @spec step_stop_fields(execution_id(), entry(), reference(), term(), [opt()]) :: keyword()
  defp step_stop_fields(execution_id, entry, span_ref, result, opts) do
    {session_id, content_hash, outcome, status, reason} = stop_shape(result)

    [
      execution_id: execution_id,
      session_id: session_id,
      content_hash: content_hash,
      entry: entry,
      outcome: outcome,
      status: status,
      reason: reason,
      span_ref: span_ref,
      invoke_id: Keyword.get(opts, :invoke_id),
      child_count: Keyword.get(opts, :child_count)
    ]
  end

  @spec stop_shape(term()) ::
          {String.t() | nil, String.t() | nil, :ok | :discarded | :error,
           Adapter.execution_status() | nil, term()}
  defp stop_shape({:ok, %Execution{} = execution, %MachineState{} = machine_state}),
    do: {session_id(machine_state), execution.content_hash, :ok, execution.status, nil}

  defp stop_shape({:ok, %Execution{} = execution}),
    do: {nil, execution.content_hash, :ok, execution.status, nil}

  defp stop_shape({:discarded, %Execution{} = execution}),
    do: {nil, execution.content_hash, :discarded, execution.status, nil}

  defp stop_shape({:error, {:budget_exhausted, _payload} = reason}),
    do: {nil, nil, :error, :failed, reason}

  defp stop_shape({:error, reason}), do: {nil, nil, :error, nil, reason}

  # The chart's own `_sessionid`, read out of the decoded datamodel - the
  # same read `StatifierPersistence.Driver` performs for event origin, and
  # no extra lookup (ADR-0009 decision 2). Permissive where the driver's
  # read is strict: an absent `_sessionid` is a missing correlation id on
  # an event, never a reason to fail a step that has already persisted.
  @spec session_id(MachineState.t()) :: String.t() | nil
  defp session_id(%MachineState{datamodel: datamodel}), do: Map.get(datamodel, "_sessionid")

  @spec entry([opt()], entry()) :: entry()
  defp entry(opts, default), do: Keyword.get(opts, :entry, default)

  # `{:discarded, execution}` with its event: the three ways a delivery becomes
  # a non-event are a closed vocabulary (`docs/telemetry.md`), and only
  # `:position_terminal` repairs anything.
  @spec discarded(Adapter.execution_record(), execution_id(), entry(), atom(), boolean()) ::
          {:discarded, Execution.t()}
  defp discarded(execution_record, execution_id, entry, reason, repaired? \\ false) do
    Telemetry.execution_discarded(
      execution_id: execution_id,
      entry: entry,
      reason: reason,
      repaired?: repaired?
    )

    {:discarded, Execution.from_record(execution_record)}
  end

  @spec terminated(execution_id(), String.t() | nil, Adapter.execution_status(), String.t() | nil) ::
          :ok
  defp terminated(execution_id, content_hash, status, reason) do
    Telemetry.execution_terminated(
      execution_id: execution_id,
      session_id: nil,
      content_hash: content_hash,
      status: status,
      driven_by: :host,
      reason: reason
    )
  end

  @spec step_loaded(
          Storage.t(),
          execution_id(),
          Adapter.execution_record(),
          MachineState.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t(),
          entry()
        ) ::
          {:ok, Execution.t(), MachineState.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp step_loaded(
         store,
         execution_id,
         execution_record,
         machine_state,
         event,
         opts,
         executor,
         entry
       ) do
    # The bare match IS the st-ADR-0064 tripwire: `from_binary/2` blanks
    # both fields unconditionally on decode, so if upstream ever stops,
    # this fails loudly here rather than silently resuming a stale
    # snapshot downstream.
    %MachineState{routes: nil, invoke_types: nil} = machine_state

    machine_state =
      machine_state
      |> MachineState.put_routes(opts[:routes])
      |> MachineState.put_invoke_types(opts[:invoke_types])

    # Resolved here rather than at the entry point deliberately: a builder
    # reads the position this step is about to act on, under the exclusion
    # this step already holds, so nothing can move between the read and
    # the step. Nothing has been executed or written yet, so a decline is
    # a discard in the full sense - the position is untouched.
    case resolve_event(event, machine_state) do
      {:ok, event} ->
        stepped(store, execution_id, machine_state, event, executor, entry, opts[:step_reporter])

      :discard ->
        discarded(execution_record, execution_id, entry, :builder_declined)
    end
  end

  @spec resolve_event(Event.t() | event_builder(), MachineState.t()) ::
          {:ok, Event.t()} | :discard
  defp resolve_event(%Event{} = event, _machine_state), do: {:ok, event}

  defp resolve_event(builder, machine_state) when is_function(builder, 1),
    do: builder.(machine_state)

  @spec stepped(
          Storage.t(),
          execution_id(),
          MachineState.t(),
          Event.t(),
          Executor.t(),
          entry(),
          step_reporter()
        ) ::
          {:ok, Execution.t(), MachineState.t()} | {:discarded, Execution.t()} | {:error, error()}
  defp stepped(store, execution_id, machine_state, event, executor, entry, reporter) do
    session_id = session_id(machine_state)
    span = open_macrostep(machine_state, session_id, :event, event)

    case Interpreter.handle_event(machine_state, event) do
      {:ok, stepped_state, effects} ->
        close_macrostep(span, session_id, :event, stepped_state, event, effects)

        with :ok <- append_input(store, execution_id, entry, event) do
          persist_tail(store, execution_id, stepped_state, effects, executor, :update, reporter)
        end

      {:error, :not_running} ->
        repair_terminal(store, execution_id, machine_state, entry)
    end
  end

  # ADR-0010's ONE write site: the single point at which a resolved event
  # HAS reached the interpreter, inside the serialized unit this step
  # already holds. That the exclusion is held is what makes the log's
  # order the execution's order and what makes the adapter's `seq` assignment
  # safe; `Driver` has no exclusion of its own and therefore no write site
  # of its own - every door it opens funnels through here carrying its own
  # `entry:` (decision 5).
  #
  # After `handle_event/2` rather than before it, because decision 5
  # appends only inputs the interpreter SAW: `{:error, :not_running}` is a
  # discard, and a log that carried the event a terminal position refused
  # would replay an execution that never happened. The three other discards -
  # a terminal execution record, a builder that declines, an adapter with no log
  # at all - never reach this function.
  #
  # A failed append fails the step, because the append is part of the
  # serialized unit and this repository does not rescue to a default at a
  # leaf. `{:error, :input_log_full}` is the sole exception: it is a
  # boundary the host declared on purpose, the log has recorded its own
  # truncation, and the execution carries on.
  @spec append_input(Storage.t(), execution_id(), entry(), Event.t()) :: :ok | {:error, error()}
  defp append_input(store, execution_id, entry, event) do
    case Storage.append_input(store, execution_id, entry, event) do
      {:ok, _seq} -> :ok
      :not_supported -> :ok
      {:error, :input_log_full} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The stored position went terminal without the execution record catching up
  # (the record said `:active`, `handle_event/2` said `:not_running`).
  # Discard the event and repair the record's status: `:done` is the only
  # chart-driven terminal state (ADR-0004 decision 6), so the repaired
  # status is `:completed`. `position: :skip` carries the stored blob
  # forward untouched - nothing stepped.
  #
  # The failure-classed tag is deliberately not consulted here, and cannot
  # be: ADR-0008's 2026-09-06 amendment reads it on the step that produced
  # the `{:done, _}` effect, and this path has no such step - it loaded a
  # position that was already terminal and produced no effects at all. A
  # record repaired here is `:completed` even if the chart settled in a
  # failure-classed final. That is a narrow window - it needs a step whose
  # position write landed while its status write did not - and widening the
  # tag to a stored position is a later record's business, not this one's.
  @spec repair_terminal(Storage.t(), execution_id(), MachineState.t(), entry()) ::
          {:discarded, Execution.t()} | {:error, error()}
  defp repair_terminal(store, execution_id, machine_state, entry) do
    with :ok <-
           Storage.update_execution(store, execution_id, machine_state, :completed,
             position: :skip
           ) do
      identity = Machine.identity(machine_state.machine)

      # Both events, because the repair is two facts at once: the delivery
      # became a non-event, and the record reached a terminal status on
      # this call. `driven_by: :chart` - the position was already terminal
      # because the chart put it there; no host asked for this.
      Telemetry.execution_discarded(
        execution_id: execution_id,
        entry: entry,
        reason: :position_terminal,
        repaired?: true
      )

      Telemetry.execution_terminated(
        execution_id: execution_id,
        session_id: session_id(machine_state),
        content_hash: identity && identity.content_hash,
        status: :completed,
        driven_by: :chart,
        reason: nil
      )

      {:discarded, execution(execution_id, :completed, identity)}
    end
  end

  # The shared tail of `create/4` and `step/5`, in ADR-0004 decision 3's
  # order: partition `:done`/`:budget_exhausted` to the lifecycle and hand
  # everything else to the executor in list order, derive the execution status,
  # assert quiescence, persist. The identity refusal runs first - the same
  # `:unidentified_chart` arm the facade's writers return - so no effect is
  # executed for an execution that cannot be persisted at all.
  @spec persist_tail(
          Storage.t(),
          execution_id(),
          MachineState.t(),
          [Statifier.Effect.t()],
          Executor.t(),
          {:insert, Adapter.metadata()} | :update,
          step_reporter()
        ) :: {:ok, Execution.t(), MachineState.t()} | {:error, error()}
  defp persist_tail(store, execution_id, machine_state, effects, executor, write, reporter) do
    case Machine.identity(machine_state.machine) do
      nil ->
        Telemetry.identity_refused(
          execution_id: execution_id,
          session_id: session_id(machine_state),
          stage: :execution,
          reason: :unidentified_chart
        )

        {:error, :unidentified_chart}

      identity ->
        {lifecycle, executable} = Enum.split_with(effects, &lifecycle_effect?/1)
        context = %{execution_id: execution_id, content_hash: identity.content_hash}
        seam = %{context: context, executor: executor, session_id: session_id(machine_state)}

        report_effects(machine_state, effects, seam)

        failures = execute_effects(executable, seam, :defer)

        {machine_state, lifecycle} = reenter_failures(machine_state, failures, seam, lifecycle)

        status = execution_status(machine_state, lifecycle)
        :ok = assert_quiescent(machine_state, lifecycle)

        with :ok <- write_execution(write, store, execution_id, machine_state, status, lifecycle) do
          report_write(write, execution_id, seam.session_id, identity, status, lifecycle)
          report_halt(machine_state, seam.session_id, status, lifecycle)

          execution_id
          |> tail_result(status, identity, lifecycle, machine_state)
          |> report_step(reporter, effects)
        end
    end
  end

  # ADR-0008's `after_step:` amendment, clause 1's list and clause 3's
  # order, on this side of the seam: the whole effect list, reported once
  # the write has landed and only for a step that actually produced a
  # result the caller will see. A `{:error, {:budget_exhausted, _}}` tail
  # result reports nothing - the execution is persisted but the entry point
  # returns an error, and the driver has no step result to hand a host.
  # The reporter records; it never acts (the `step_reporter:` typedoc).
  @spec report_step(
          {:ok, Execution.t(), MachineState.t()} | {:error, error()},
          step_reporter(),
          [Statifier.Effect.t()]
        ) :: {:ok, Execution.t(), MachineState.t()} | {:error, error()}
  defp report_step(result, nil, _effects), do: result

  defp report_step({:ok, _execution, _machine_state} = result, reporter, effects) do
    reporter.(effects)

    result
  end

  defp report_step(result, _reporter, _effects), do: result

  # The lifecycle events the persist tail owns, emitted only once the write
  # has actually landed: a create reports `[..., :execution, :created]`, and any
  # write that reached a terminal status reports `[..., :execution, :terminated]`
  # with `driven_by: :chart` - `fail/4` and `cancel/3` are the `:host`
  # ones and report their own.
  #
  # `child?` and `metadata?` are both read off the merged map rather than
  # plumbed: the reserved linkage key is what makes an execution a child
  # (ADR-0008 decision 2), and what is left after dropping it is exactly
  # the host's own `metadata:` (ADR-0006 decision 1). Neither the map nor
  # any key of it is ever emitted - only the two booleans (ADR-0009
  # decision 7).
  @spec report_write(
          {:insert, Adapter.metadata()} | :update,
          execution_id(),
          String.t() | nil,
          Identity.t(),
          Adapter.execution_status(),
          [Statifier.Effect.t()]
        ) :: :ok
  defp report_write({:insert, metadata}, execution_id, session_id, identity, status, lifecycle) do
    Telemetry.execution_created(
      execution_id: execution_id,
      session_id: session_id,
      content_hash: identity.content_hash,
      child?: Map.has_key?(metadata, Linkage.reserved_key()),
      metadata?: map_size(Map.delete(metadata, Linkage.reserved_key())) > 0
    )

    report_termination(execution_id, session_id, identity, status, lifecycle)
  end

  defp report_write(:update, execution_id, session_id, identity, status, lifecycle),
    do: report_termination(execution_id, session_id, identity, status, lifecycle)

  @spec report_termination(
          execution_id(),
          String.t() | nil,
          Identity.t(),
          Adapter.execution_status(),
          [Statifier.Effect.t()]
        ) :: :ok
  defp report_termination(_execution_id, _session_id, _identity, :active, _lifecycle), do: :ok

  defp report_termination(execution_id, session_id, identity, status, lifecycle) do
    Telemetry.execution_terminated(
      execution_id: execution_id,
      session_id: session_id,
      content_hash: identity.content_hash,
      status: status,
      driven_by: :chart,
      reason: failure_string(lifecycle)
    )
  end

  # -- family one: the interpreter's own events, as a stepping driver -----
  #
  # ADR-0009 decision 2 and `st-ADR-0067` decisions 2-4: a durably-stepped
  # macrostep is structurally the same `[:statifier, :session, ...]` family
  # a session-stepped one is, distinguished only by `driver: :persistence`,
  # because these call sites call the same `Statifier.Telemetry` functions
  # `Statifier.Session` calls. `docs/telemetry.md`'s family-one table is
  # the contract; `st-ADR-0067` decision 3's applicability table is why
  # `:terminate` and `:interpret` appear nowhere in this module.
  #
  # `session_id` is always the chart's own `_sessionid`, read out of the
  # decoded datamodel by `session_id/1` - never a lookup, never invented.

  # Family one's execution-scoped opening: `:init` fires exactly once per logical
  # execution, here, with `resumed: false` (every `step/5` is a rehydration, not
  # a boot, so an `:init` per load would fire thousands of times per execution and
  # would mean "process boot", which does not exist on this path), and the
  # `:initialize` span brackets the one `Interpreter.initialize/2` call the
  # execution ever makes. `invoked_by` is `nil` unconditionally: it names a live
  # parent pid, and a durable subchart's parent is an execution record, not a
  # process (ADR-0008).
  #
  # Both halves are emitted *after* that call rather than around it because
  # the `session_id` they carry is what the call mints. `span_start` is read
  # by the caller before the advance, so `duration` still measures the core
  # call alone - the same shape, for the same reason, as
  # `Statifier.Session.init_boot/3`, which also emits `init` and
  # `macrostep_start` only once `boot/6` has returned a `%MachineState{}`.
  @spec report_initialized(Machine.t(), MachineState.t(), [Statifier.Effect.t()], integer()) ::
          :ok
  defp report_initialized(machine, machine_state, effects, span_start) do
    session_id = session_id(machine_state)
    span_ref = make_ref()

    CoreTelemetry.init(@driver, session_id, machine, machine_state, nil, false)
    CoreTelemetry.macrostep_start(@driver, session_id, :initialize, nil, span_ref)

    CoreTelemetry.macrostep_stop(
      @driver,
      session_id,
      :initialize,
      machine_state,
      nil,
      macrostep_outcome(machine_state, effects),
      span_start,
      span_ref
    )
  end

  # Opens a macrostep span around a core advance, or opens nothing for a
  # position the advance entry will refuse: `%MachineState{running: false}`
  # is verbatim `Interpreter.handle_event/2`'s and
  # `Interpreter.deliver_internal/5`'s `{:error, :not_running}` guard, so a
  # delivery that performs no advance emits no half of a pair the bridge
  # would then have to time out.
  @spec open_macrostep(MachineState.t(), String.t() | nil, :event | :internal, Event.t() | nil) ::
          span()
  defp open_macrostep(%MachineState{running: false}, _session_id, _trigger, _event), do: nil

  defp open_macrostep(%MachineState{}, session_id, trigger, event) do
    span_start = System.monotonic_time()
    span_ref = make_ref()

    CoreTelemetry.macrostep_start(@driver, session_id, trigger, event, span_ref)

    {span_start, span_ref}
  end

  # Closes the span `open_macrostep/4` opened. Both halves are emitted
  # inside one synchronous call, so `st-ADR-0067` decision 5's constraint -
  # a macrostep span never crosses a persist boundary - holds structurally
  # here rather than by discipline.
  @spec close_macrostep(
          span(),
          String.t() | nil,
          :event | :internal,
          MachineState.t(),
          Event.t() | nil,
          [Statifier.Effect.t()]
        ) :: :ok
  defp close_macrostep(nil, _session_id, _trigger, _machine_state, _event, _effects), do: :ok

  defp close_macrostep(
         {span_start, span_ref},
         session_id,
         trigger,
         machine_state,
         event,
         effects
       ) do
    CoreTelemetry.macrostep_stop(
      @driver,
      session_id,
      trigger,
      machine_state,
      event,
      macrostep_outcome(machine_state, effects),
      span_start,
      span_ref
    )
  end

  # The stop half's `outcome`: what the *macrostep* did, read off the same
  # two facts `execution_status/2` reads off, so a span and a record can never
  # disagree about which of them happened. It deliberately does not carry
  # `execution_status/2`'s third arm: a failure-classed final is still a `:done`
  # macrostep (ADR-0008's 2026-09-06 amendment, decision 2 - "a chart that
  # says it failed has not malfunctioned, it has finished"), and the
  # `status` field beside this one on the same span already carries the
  # `:failed` the tag produced. `:cancelled` is upstream's fourth
  # value and is unreachable here: this package never calls
  # `Interpreter.cancel/1`, and `cancel/3` is a host decision about the execution
  # record that reaches no interpreter at all (ADR-0004 decision 6).
  @spec macrostep_outcome(MachineState.t(), [Statifier.Effect.t()]) ::
          :quiescent | :done | :budget_exhausted
  defp macrostep_outcome(machine_state, effects) do
    cond do
      budget_exhausted?(effects) -> :budget_exhausted
      machine_state.status == :done -> :done
      true -> :quiescent
    end
  end

  # Family one's per-effect events - `st-ADR-0067` decision 3's `:effect`
  # (11 kinds) and `:trace` (9 kinds) rows, which
  # `Statifier.Telemetry.effect/4` dispatches between on the effect's own
  # tag. The `trace: true` gate stays in the core, which simply produces no
  # trace effects when it is off (the flag rides the position,
  # `st-ADR-0060`), so there is no gate to restate here.
  #
  # Every effect the advance produced, in the core's own list order, before
  # any of them reaches the host executor - deliberately not interleaved
  # with execution. This family reports what the *chart* emitted; what the
  # host then made of it is family two's
  # `[:statifier_persistence, :effect, :failed]`. Interleaving would also
  # have to place the two lifecycle effects `execute_effects/3` never sees
  # (`:done`, `:budget_exhausted`) somewhere other than where the
  # interpreter put them, and a `:done` reported before the sends that
  # preceded it is a worse timeline than one reported a few microseconds
  # early.
  @spec report_effects(MachineState.t(), [Statifier.Effect.t()], seam()) :: :ok
  defp report_effects(%MachineState{machine: machine}, effects, seam) do
    Enum.each(effects, &CoreTelemetry.effect(@driver, seam.session_id, machine, &1))
  end

  # Family one's `:halt`: the step whose outcome is terminal, emitted once
  # the write has landed for the same reason `report_write/6` is - a step
  # that could not be persisted did not happen. `fail/4` and `cancel/3`
  # reach no interpreter, so they emit nothing here; upstream has no event
  # for a host abandoning an execution and this package does not mint one. Family
  # two's `[:statifier_persistence, :execution, :terminated]` reports those, with
  # `driven_by: :host`.
  @spec report_halt(
          MachineState.t(),
          String.t() | nil,
          Adapter.execution_status(),
          [Statifier.Effect.t()]
        ) :: :ok
  defp report_halt(_machine_state, _session_id, :active, _lifecycle), do: :ok

  defp report_halt(machine_state, session_id, _status, lifecycle) do
    reason = if budget_exhausted?(lifecycle), do: :budget_exhausted, else: :done

    CoreTelemetry.halt(@driver, session_id, reason, machine_state)
  end

  # The persisted-execution return: `{:ok, ...}` for a live or completed execution,
  # `{:error, {:budget_exhausted, payload}}` AFTER the `:failed` record is
  # durable, so the caller sees both the state and the reason.
  @spec tail_result(
          execution_id(),
          Adapter.execution_status(),
          Identity.t(),
          [Statifier.Effect.t()],
          MachineState.t()
        ) :: {:ok, Execution.t(), MachineState.t()} | {:error, error()}
  defp tail_result(execution_id, status, identity, lifecycle, machine_state) do
    case budget_effect(lifecycle) do
      nil ->
        {:ok,
         execution(
           execution_id,
           status,
           identity,
           done_effect(lifecycle),
           failure_string(lifecycle)
         ), machine_state}

      %BudgetExhausted{} = payload ->
        {:error, {:budget_exhausted, payload}}
    end
  end

  # `{:done, %Done{donedata: donedata}}` is consumed into a terminal status
  # - `:completed`, or `:failed` where the donedata carries the
  # failure-classed tag `failure_classed_final?/1` reads (ADR-0004 decision
  # 6 and its 2026-09-06 note) - and, from ADR-0008 decision 3, also
  # surfaced verbatim, tag included: a
  # durable subchart's parent is answered with its child's donedata, and this
  # is the only moment it exists. It is deliberately not persisted - a
  # position that has reached a final state has no configuration left to
  # carry it, and inventing a column for it would make an execution record a
  # result store. `nil` on every step that did not just complete the execution -
  # at most one `:done` effect is ever produced per step.
  @spec done_effect([Statifier.Effect.t()]) :: term() | nil
  defp done_effect(lifecycle_effects) do
    case Enum.find(lifecycle_effects, &match?({:done, _payload}, &1)) do
      {:done, %Done{donedata: donedata}} -> donedata
      nil -> nil
    end
  end

  # ADR-0004 decision 4's error re-entry: each executor failure on an
  # actionable effect re-enters the chart as `error.communication` through
  # `Interpreter.deliver_internal/5` - st-ADR-0051's failed-communication
  # row, the only row an executor failure can be, because the core accepted
  # the effect before emitting it. Observational failures are discarded:
  # observation must never steer an execution. Effects the re-entries emit go
  # through the executor too, but their failures are NOT re-entered (single
  # wave), so a deterministically failing executor cannot recurse here.
  # `{:error, :not_running}` (a re-entry itself reached a final state) ends
  # the wave, as does a re-entry exhausting the macrostep budget - the tail
  # then reads status normally. A wave is never opened into a state the
  # primary pass already reported budget-exhausted.
  #
  # This is also where `[:statifier_persistence, :effect, :failed]`'s
  # `reentered?` is settled for the primary pass, which is why the primary
  # pass defers its emission here rather than emitting inside
  # `execute_effects/3`: whether a failure opened a re-entry is not known
  # at the moment it is collected. A wave's own failures emit immediately
  # with `reentered?: false`, because the wave is single by design.
  @spec reenter_failures(
          MachineState.t(),
          [{Statifier.Effect.t(), term()}],
          seam(),
          [Statifier.Effect.t()]
        ) :: {MachineState.t(), [Statifier.Effect.t()]}
  defp reenter_failures(machine_state, failures, seam, lifecycle) do
    {machine_state, lifecycle, _halted?} =
      if budget_exhausted?(lifecycle) do
        Enum.each(failures, &report_failure(&1, seam, false))
        {machine_state, lifecycle, true}
      else
        Enum.reduce(failures, {machine_state, lifecycle, false}, &reenter_one(&1, &2, seam))
      end

    {machine_state, lifecycle}
  end

  @spec reenter_one(
          {Statifier.Effect.t(), term()},
          {MachineState.t(), [Statifier.Effect.t()], boolean()},
          seam()
        ) :: {MachineState.t(), [Statifier.Effect.t()], boolean()}
  defp reenter_one(failure, {machine_state, lifecycle, true}, seam) do
    report_failure(failure, seam, false)
    {machine_state, lifecycle, true}
  end

  defp reenter_one({effect, _reason} = failure, {machine_state, lifecycle, false}, seam) do
    case reentry_origin(effect) do
      :observational ->
        report_failure(failure, seam, false)
        {machine_state, lifecycle, false}

      {origin, opts} ->
        {flow, reentered?, {machine_state, lifecycle}} =
          deliver_reentry({machine_state, lifecycle}, origin, opts, seam)

        report_failure(failure, seam, reentered?)
        {machine_state, lifecycle, flow == :halt}
    end
  end

  @spec deliver_reentry(
          {MachineState.t(), [Statifier.Effect.t()]},
          Statifier.Event.Cause.origin(),
          keyword(),
          seam()
        ) :: {:cont | :halt, boolean(), {MachineState.t(), [Statifier.Effect.t()]}}
  defp deliver_reentry({machine_state, lifecycle} = acc, origin, opts, seam) do
    # The wave is a core advance like any other, so it gets its own
    # macrostep span, nested inside the `:event` span the primary pass
    # already closed the way `st-ADR-0039` re-entry nests one inside a
    # session's (`st-ADR-0067` decision 5 names this case explicitly). An
    # already-terminal position opens none: `open_macrostep/4` reads the
    # same `running: false` guard `deliver_internal/5` refuses on, so the
    # `{:error, :not_running}` arm below can never leave a start half
    # without its stop.
    span = open_macrostep(machine_state, seam.session_id, :internal, nil)

    case Interpreter.deliver_internal(
           machine_state,
           :platform,
           "error.communication",
           origin,
           opts
         ) do
      {:ok, machine_state, wave_effects} ->
        close_macrostep(span, seam.session_id, :internal, machine_state, nil, wave_effects)
        report_effects(machine_state, wave_effects, seam)

        {wave_lifecycle, wave_executable} = Enum.split_with(wave_effects, &lifecycle_effect?/1)

        # Single wave: these failures are dropped, never re-entered - so
        # they report themselves, with `reentered?: false`.
        _wave_failures = execute_effects(wave_executable, seam, :emit)

        lifecycle = lifecycle ++ wave_lifecycle
        flow = if budget_exhausted?(wave_lifecycle), do: :halt, else: :cont
        {flow, true, {machine_state, lifecycle}}

      # The re-entry itself reached a final state, so nothing was
      # delivered: this failure did not re-enter the chart either.
      {:error, :not_running} ->
        {:halt, false, acc}
    end
  end

  # The origin each re-entry carries, mirroring the shapes upstream's
  # session builds on its own failed-communication paths - this package
  # invents no origin vocabulary (every arm below is a
  # `t:Statifier.Event.Cause.origin/0` constructor):
  #
  # - `:invoke` -> `{:invoke, state_index, invoke_index}` with no opts,
  #   exactly as `Statifier.Session.invoke_error/4` builds it
  #   (`deps/statifier/lib/statifier/session.ex`, the st-ADR-0039 decision 4
  #   write).
  # - `:send`/`:send_delayed` -> `{:content, c_index, owner}` with the
  #   failing send's `sendid`, exactly as `Statifier.Session.origin_of/1`
  #   and `communication_error/4` build it.
  # - `:cancel` -> the same `{:content, c_index, owner}` arm (the `<cancel>`
  #   element's own content node carries both fields for exactly this
  #   identity), with no `sendid` - there is no failing `<send>` here to
  #   name one.
  # - `:cancel_invoke`/`:autoforward` -> `{:state, state_index}`, the
  #   platform-raised-with-no-content-node arm, since neither payload
  #   carries an `invoke_index` to name the `{:invoke, _, _}` arm with.
  #
  # Everything else is observational (`:log`, `:datamodel_change`,
  # `:datamodel_init`, `:trace`) and its failure is discarded.
  @spec reentry_origin(Statifier.Effect.t()) ::
          {Statifier.Event.Cause.origin(), keyword()} | :observational
  defp reentry_origin({:invoke, %Invoke{state_index: state_index, invoke_index: invoke_index}}),
    do: {{:invoke, state_index, invoke_index}, []}

  defp reentry_origin({:send, %Send{c_index: c_index, owner: owner, send_id: send_id}}),
    do: {{:content, c_index, owner}, [sendid: send_id]}

  defp reentry_origin({:send_delayed, %SendDelayed{} = payload}),
    do: {{:content, payload.c_index, payload.owner}, [sendid: payload.send_id]}

  defp reentry_origin({:cancel, %Cancel{c_index: c_index, owner: owner}}),
    do: {{:content, c_index, owner}, []}

  defp reentry_origin({:cancel_invoke, %CancelInvoke{state_index: state_index}}),
    do: {{:state, state_index}, []}

  defp reentry_origin({:autoforward, %Autoforward{state_index: state_index}}),
    do: {{:state, state_index}, []}

  defp reentry_origin(_observational_effect), do: :observational

  @spec lifecycle_effect?(Statifier.Effect.t()) :: boolean()
  defp lifecycle_effect?({:done, _payload}), do: true
  defp lifecycle_effect?({:budget_exhausted, _payload}), do: true
  defp lifecycle_effect?(_effect), do: false

  @spec execute_effects([Statifier.Effect.t()], seam(), :emit | :defer) ::
          [{Statifier.Effect.t(), term()}]
  defp execute_effects(effects, seam, report) do
    effects
    |> Enum.reduce([], &execute_one(&1, &2, seam, report))
    |> Enum.reverse()
  end

  @spec execute_one(
          Statifier.Effect.t(),
          [{Statifier.Effect.t(), term()}],
          seam(),
          :emit | :defer
        ) :: [{Statifier.Effect.t(), term()}]
  defp execute_one(effect, failures, seam, report) do
    case Executor.run(seam.executor, effect, seam.context) do
      :ok -> failures
      {:error, reason} -> collect({effect, reason}, failures, seam, report)
    end
  end

  @spec collect(
          {Statifier.Effect.t(), term()},
          [{Statifier.Effect.t(), term()}],
          seam(),
          :emit | :defer
        ) :: [{Statifier.Effect.t(), term()}]
  defp collect(failure, failures, seam, :emit) do
    report_failure(failure, seam, false)
    [failure | failures]
  end

  defp collect(failure, failures, _seam, :defer), do: [failure | failures]

  # `[:statifier_persistence, :effect, :failed]` for one executor verdict
  # (ADR-0009 decision 3). `executor` is the module, or `:fun` for the
  # arity-2 form `t:StatifierPersistence.Executor.t/0` also accepts -
  # there is no name to report for an anonymous function, and reporting
  # its `inspect/1` would be an unbounded dimension.
  #
  # `reason` is the executor's own `{:error, reason}` term unchanged, so a
  # consumer folding it into a metric dimension must narrow it first
  # (`docs/telemetry.md`, "Cardinality and disclosure"). The effect's own
  # payload never travels: only its kind atom.
  @spec report_failure({Statifier.Effect.t(), term()}, seam(), boolean()) :: :ok
  defp report_failure({{kind, _payload}, reason}, seam, reentered?) do
    Telemetry.effect_failed(
      execution_id: seam.context.execution_id,
      session_id: seam.session_id,
      content_hash: seam.context.content_hash,
      kind: kind,
      executor: executor_name(seam.executor),
      reason: reason,
      reentered?: reentered?
    )
  end

  @spec executor_name(Executor.t()) :: module() | :fun
  defp executor_name(executor) when is_atom(executor), do: executor
  defp executor_name(_executor), do: :fun

  # `:done` is the only path to `:completed` (ADR-0004 decision 6, and its
  # 2026-09-06 note: one-directional, so a `:done` effect no longer always
  # completes). Two routes reach `:failed`, and the arm order here is the
  # whole of the difference between them (ADR-0008's 2026-09-06 amendment,
  # decision 2): `:budget_exhausted` - from the primary pass or from a
  # re-entry wave - first, then a failure-classed final, then `:done`. Both
  # middle conditions hold on the same step, because a failure-classed
  # final *is* a top-level final, and the tag is the tie-break.
  @spec execution_status(MachineState.t(), [Statifier.Effect.t()]) :: Adapter.execution_status()
  defp execution_status(machine_state, lifecycle_effects) do
    warn_legacy_execution_status_key(lifecycle_effects)

    cond do
      budget_exhausted?(lifecycle_effects) -> :failed
      failure_classed_final?(lifecycle_effects) -> :failed
      machine_state.status == :done -> :completed
      true -> :active
    end
  end

  @spec budget_exhausted?([Statifier.Effect.t()]) :: boolean()
  defp budget_exhausted?(lifecycle_effects),
    do: Enum.any?(lifecycle_effects, &match?({:budget_exhausted, _payload}, &1))

  # ADR-0008's 2026-09-06 amendment decision 1: a chart says its execution failed
  # by settling in a final whose `<donedata>` carries the reserved
  # package-owned key below with the value `"failed"`. The value set is
  # closed at that one string - any other value, and any donedata that is
  # not a map, is ignored, and the execution takes the status it would have taken
  # with no key at all. The colon separator is deliberate: it is not a
  # predicator identifier character, so the reserved key can be written by
  # any chart and pathed into by none.
  #
  # The key is never stripped. `done_effect/1` hands the resolved
  # `<donedata>` on verbatim, tag included, because the tag's second reader
  # is the parent's collect over a failed child (the same posture ADR-0006
  # decision 1 takes toward metadata).
  @execution_status_key "statifier_persistence:execution_status"

  # ADR-0011 decision 4: the pre-0.12.0 spelling of the key above. A chart's
  # `<param>` is data already committed to a repository somewhere and may be
  # running, so this package reads the old key for one release - 0.12.0 - and
  # drops it in 0.13.0. It is the only transitional reader the execution
  # rename ships. The new key wins wherever both are present, and reading the
  # old one logs a deprecation line naming the new one.
  @legacy_execution_status_key "statifier_persistence:run_status"
  @failed_execution_status "failed"

  @spec failure_classed_final?([Statifier.Effect.t()]) :: boolean()
  defp failure_classed_final?(lifecycle_effects) do
    case done_effect(lifecycle_effects) do
      %{@execution_status_key => status} ->
        status == @failed_execution_status

      %{@legacy_execution_status_key => status} ->
        status == @failed_execution_status

      _donedata ->
        false
    end
  end

  # Exactly one line per step that reads the retired key, at `:debug`: the
  # host is not doing anything wrong yet, and the chart author the line names
  # is the person who has to act. It is emitted from `execution_status/2`
  # rather than from `failure_classed_final?/1` because the predicate is
  # asked several times per step (`failure_string/1` asks it again) while the
  # status is decided once.
  @spec warn_legacy_execution_status_key([Statifier.Effect.t()]) :: :ok
  defp warn_legacy_execution_status_key(lifecycle_effects) do
    case done_effect(lifecycle_effects) do
      %{@execution_status_key => _status} -> :ok
      %{@legacy_execution_status_key => _status} -> log_legacy_execution_status_key()
      _donedata -> :ok
    end
  end

  @spec log_legacy_execution_status_key() :: :ok
  defp log_legacy_execution_status_key do
    Logger.debug(
      "statifier_persistence: the donedata key #{inspect(@legacy_execution_status_key)} is " <>
        "deprecated and is read for the last time in 0.12.0; use " <>
        "#{inspect(@execution_status_key)} instead (ADR-0011 decision 4)."
    )
  end

  # The execution record's short `failure` string - psql-console readable, not
  # an inspect dump (ADR-0004 decision 1) - and the same string
  # `[:statifier_persistence, :execution, :terminated]` reports as `reason` and
  # `Driver.maybe_answer_parent/3` sends the parent as `{:failed, reason:
  # ...}`, so the event, the row and the answer can never disagree.
  #
  # Its arms mirror `execution_status/2`'s, budget first: an execution that exhausted
  # its macrostep budget and one that reached a failure-classed final are
  # both `:failed`, and this string is what tells a reader which
  # (amendment decision 4).
  @spec failure_string([Statifier.Effect.t()]) :: String.t() | nil
  defp failure_string(lifecycle_effects) do
    case budget_effect(lifecycle_effects) do
      %BudgetExhausted{budget: budget} ->
        "budget_exhausted: #{budget} rounds"

      nil ->
        if failure_classed_final?(lifecycle_effects), do: "failed_final"
    end
  end

  @spec budget_effect([Statifier.Effect.t()]) :: BudgetExhausted.t() | nil
  defp budget_effect(lifecycle_effects) do
    Enum.find_value(lifecycle_effects, fn
      {:budget_exhausted, %BudgetExhausted{} = payload} -> payload
      _effect -> nil
    end)
  end

  # A non-quiescent state without `:budget_exhausted` cannot come out of
  # `initialize/2` or `handle_event/2` - both fold to quiescence - so a
  # false here is a bug in this loop, not a caller error, and it raises
  # deliberately rather than persisting a position the resume recipe cannot
  # honor.
  @spec assert_quiescent(MachineState.t(), [Statifier.Effect.t()]) :: :ok
  defp assert_quiescent(machine_state, lifecycle_effects) do
    if budget_exhausted?(lifecycle_effects) or MachineState.internal_queue_empty?(machine_state) do
      :ok
    else
      raise "loop bug: non-quiescent MachineState reached the persist tail " <>
              "without :budget_exhausted - upstream's quiescence fold makes this unreachable"
    end
  end

  # A budget-exhausted state is not quiescent, so its position is never
  # persisted: `:skip` stores `nil` on insert and carries the stored blob
  # forward on update (ADR-0004 decision 1). The failure string is short
  # and prefixed - a psql-console reason, not an inspect dump.
  @spec write_execution(
          {:insert, Adapter.metadata()} | :update,
          Storage.t(),
          execution_id(),
          MachineState.t(),
          Adapter.execution_status(),
          [Statifier.Effect.t()]
        ) :: :ok | {:error, error()}
  defp write_execution(write, store, execution_id, machine_state, status, lifecycle_effects) do
    position = if budget_exhausted?(lifecycle_effects), do: :skip, else: :persist
    opts = [position: position, failure: failure_string(lifecycle_effects)]

    case write do
      {:insert, metadata} ->
        Storage.insert_execution(store, execution_id, machine_state, status, [
          {:metadata, metadata} | opts
        ])

      :update ->
        Storage.update_execution(store, execution_id, machine_state, status, opts)
    end
  end

  # `failure` carries the same string `write_execution/6` persisted and
  # `report_termination/5` reported, so the struct a step hands back and
  # the row it just wrote agree. It matters beyond tidiness:
  # `StatifierPersistence.Driver`'s automatic answer reads `execution.failure`
  # off exactly this struct to tell a durable parent *why* its child
  # failed, and before ADR-0008's 2026-09-06 amendment no drive could
  # produce a `:failed` here at all - budget exhaustion returns an error
  # tuple instead of an execution - so the field had nothing to carry and was
  # hardcoded `nil`.
  @spec execution(
          execution_id(),
          Adapter.execution_status(),
          Identity.t(),
          term(),
          String.t() | nil
        ) :: Execution.t()
  defp execution(execution_id, status, identity, donedata \\ nil, failure \\ nil) do
    %Execution{
      execution_id: execution_id,
      status: status,
      content_hash: identity.content_hash,
      failure: failure,
      donedata: donedata
    }
  end
end
