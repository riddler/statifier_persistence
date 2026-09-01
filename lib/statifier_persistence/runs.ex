defmodule StatifierPersistence.Runs do
  @moduledoc """
  The run lifecycle: create and step durable runs with no live Session
  process, the loop this package exists to package.

  A step runs in ADR-0004 decision 3's order, and the order is the
  contract: liveness check on the run record -> load (guarded) -> re-stamp
  `routes`/`invoke_types` unconditionally (with the nil tripwire from
  st-ADR-0064: the fields are pattern-matched `nil` before stamping, so an
  upstream regression fails loudly here, not silently downstream) -> step
  via `Interpreter.handle_event/2` -> execute effects via the executor
  seam -> consume `:done` and `:budget_exhausted` into run status -> assert
  `MachineState.internal_queue_empty?/1` -> persist.

  Effect execution is at-least-once: a crash between step and persist
  re-drives the same event and re-emits the same effects with identical
  deterministic keys (st-ADR-0054 decision 3, st-ADR-0059), and this loop
  never dedupes - idempotency is the consumer's. `:done` is the only path
  to `:completed` (ADR-0004 decision 6); an event delivered to a terminal
  run is discarded with a typed `{:discarded, run}` result, never an
  exception and never a silent step.

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

  Concurrent deliveries to one run are ordered by a pluggable per-run
  serialization strategy (ADR-0004 decision 5): every entry point runs its
  fetch-to-persist tail inside the strategy's
  `c:StatifierPersistence.Serialization.with_run/3`, selected per call with
  `serialization: {module, config}` and defaulting to
  `{StatifierPersistence.Serialization.AdapterLock, store}` - the adapter's
  own optional `lock_run/3`. A strategy refusal surfaces unchanged as
  `{:error, {:serialization, reason}}`.
  """

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
  alias StatifierPersistence.{Executor, Run, Storage, Telemetry}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage.Adapter

  @typedoc "A run's caller-supplied opaque key (ADR-0004 decision 2)."
  @type run_id :: Adapter.run_id()

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
  An event `step/5` can only build once the run's position is loaded.

  Called with the loaded, re-stamped `t:Statifier.MachineState.t/0`, inside
  the serialization strategy's `with_run/3` and before
  `Statifier.Interpreter.handle_event/2` - so what it reads and what the
  step acts on are the same position under the same exclusion. `{:ok,
  event}` steps that event; `:discard` steps nothing and returns
  `{:discarded, run}`.

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
  or create has persisted its `:failed` run record, plus the serialization
  strategy's own refusal, surfaced unchanged
  (`{:serialization, :not_supported}` from the default strategy over an
  adapter with no `lock_run/3`).
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
    identities stored beside the run record (ADR-0006 decision 1),
    defaulting to `%{}`. Identities only, never personal data (decision 2);
    an adapter that cannot store a non-empty map refuses the create with
    `{:error, :metadata_unsupported}` (decision 3).
  - `serialization:` - the `{module, config}` per-run serialization
    strategy the fetch-to-persist tail runs inside (ADR-0004 decision 5;
    `fail/4` accepts it too). Defaults to
    `{StatifierPersistence.Serialization.AdapterLock, store}`.
  - `entry:` - this package's own, never a host's, and telemetry-only: the
    public door this drive came through, carried on
    `[:statifier_persistence, :run, :step, :start | :stop]` and
    `[:statifier_persistence, :run, :discarded]` as `entry` (ADR-0009,
    `docs/telemetry.md`). `StatifierPersistence.Driver` sets it to
    `:done_invocation`, `:failed_invocation` or `:answer_parent` on the
    doors that reach `step/5` rather than being one of its own; every
    other entry point derives its own (`:create`, `:step`, `:fail`,
    `:cancel`) and this option changes nothing but the reported value.
  - `linkage:` (`create/4` only) - this package's own, never a host's. Set
    by the durable subchart `start_child` clause (Phase 3) to record a
    child's parent under the reserved metadata namespace
    (`StatifierPersistence.Run.Linkage`, ADR-0008 decision 2). A host
    supplies `metadata:` for its own identities; supplying `linkage:` from
    outside this package is a caller bug the same way a malformed
    `metadata:` is.
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

  @typedoc """
  The fixed vocabulary of public doors `entry` names on this package's own
  telemetry (`docs/telemetry.md`). It is the dimension an operator slices
  step latency by first, because a `:done_invocation` step and a `:step`
  step have different expected shapes.
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
  Creates a run: `Statifier.Interpreter.initialize/2` (which cannot fail),
  then the shared persist tail - effects through the executor seam,
  `:done`/`:budget_exhausted` consumed into run status, quiescence
  asserted, the record inserted with its encoded position.

  Create-exactly-once rests on the adapter's atomic `:run_exists` refusal
  (ADR-0004 decision 2), not on a pre-check here: creating an existing
  `run_id` returns `{:error, :run_exists}`.

  A create whose `initialize/2` exhausts its macrostep budget persists a
  `:failed` run with no position blob (there is no quiescent position to
  store - ADR-0004 decision 1) and then returns
  `{:error, {:budget_exhausted, payload}}`, so the caller sees both the
  durable state and the reason.

  `metadata:` rides through to the inserted run record unchanged (ADR-0006
  decision 1). Create is the only place it is set - `step/5` and `fail/4`
  carry the stored map forward and take no `metadata:` of their own - and
  an adapter that cannot store a non-empty map refuses here, before any
  effect is executed: `{:error, :metadata_unsupported}`.
  """
  @spec create(store :: Storage.t(), run_id :: run_id(), machine :: Machine.t(), opts :: [opt()]) ::
          {:ok, Run.t(), MachineState.t()} | {:error, error()}
  def create(%Storage{} = store, run_id, %Machine{} = machine, opts) do
    executor = Keyword.fetch!(opts, :executor)

    # ADR-0006 decision 3's refusal is at open, and "at open" has to mean
    # before initialize/2's effects reach the executor: a create the
    # adapter will refuse must not fire an effect on its way to the
    # refusal, for the same reason the identity refusal runs first below.
    #
    # Only the `metadata:` pair crosses, never the whole list (sp-3kk).
    # `check_metadata/2`'s contract is `[Storage.run_write_opt()]` -
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
    # is refused before any effect runs, the same ordering ADR-0006
    # decision 3 set for a host's own metadata.
    metadata = metadata(opts)

    with :ok <- Storage.check_metadata(store, metadata: metadata) do
      {machine_state, effects} =
        Interpreter.initialize(machine, Keyword.get(opts, :initialize, []))

      serialized(store, run_id, :create, opts, fn ->
        persist_tail(store, run_id, machine_state, effects, executor, {:insert, metadata})
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
  Delivers one external event to a run, in ADR-0004 decision 3's order (the
  moduledoc quotes it).

  An event delivered to a terminal run returns `{:discarded, run}` from the
  run record alone, before any position decode. `handle_event/2`'s
  `{:error, :not_running}` arm is the structural backstop for a run record
  whose `:active` status lies about a terminal stored position: it discards
  too, and repairs the record's status to `:completed` on the way out.

  `event` may also be a `t:event_builder/0` - a fun the loaded position is
  handed, for an event only the position can build or decline. A builder
  that declines discards the delivery through the same `{:discarded, run}`
  arm.
  """
  @spec step(
          store :: Storage.t(),
          run_id :: run_id(),
          machine :: Machine.t(),
          event :: Event.t() | event_builder(),
          opts :: [opt()]
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  def step(%Storage{} = store, run_id, %Machine{} = machine, event, opts)
      when is_struct(event, Event) or is_function(event, 1) do
    executor = Keyword.fetch!(opts, :executor)
    entry = entry(opts, :step)

    serialized(store, run_id, entry, opts, fn ->
      step_tail(store, run_id, machine, event, opts, executor, entry)
    end)
  end

  @spec step_tail(
          Storage.t(),
          run_id(),
          Machine.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t(),
          entry()
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp step_tail(store, run_id, machine, event, opts, executor, entry) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        discarded(run_record, run_id, entry, :terminal_run)

      {:ok, run_record} ->
        with {:ok, machine_state} <- Storage.load_run_position(store, run_id, machine) do
          step_loaded(store, run_id, run_record, machine_state, event, opts, executor, entry)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Abandons a run: the only host-driven terminal transition (ADR-0004
  decision 6). No interpreter is involved - abandonment is a host decision
  about the run, not a chart transition - so the stored position is left
  untouched and only the record's status and failure reason change.

  A terminal run is discarded, same as `step/5`: `{:discarded, run}`.
  `reason` is the short string stored as the run's `failure` - keep it a
  prefixed, console-readable reason, not an inspect dump.

  `opts` accepts `serialization:` only - the same `{module, config}`
  strategy `create/4` and `step/5` take, with the same default.
  """
  @spec fail(store :: Storage.t(), run_id :: run_id(), reason :: String.t(), opts :: keyword()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  def fail(%Storage{} = store, run_id, reason, opts \\ []) when is_binary(reason) do
    serialized(store, run_id, :fail, opts, fn ->
      fail_tail(store, run_id, reason)
    end)
  end

  @spec fail_tail(Storage.t(), run_id(), String.t()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  defp fail_tail(store, run_id, reason) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        discarded(run_record, run_id, :fail, :terminal_run)

      {:ok, run_record} ->
        with :ok <- Storage.update_run_status(store, run_id, :failed, failure: reason) do
          terminated(run_id, run_record.content_hash, :failed, reason)
          {:ok, Run.from_record(%{run_record | status: :failed, failure: reason})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancels a run: the second host-driven terminal transition (ADR-0004
  decision 6 as extended by ADR-0008 decision 5), and the one a cascading
  cancel writes through.

  Cancellation **retains**: no record and no position is deleted, no
  interpreter is involved, and the stored position is left untouched - only
  the record's status changes, to `:cancelled`. A run that is already
  terminal - cancelled by an earlier, interrupted cascade included - is
  discarded with `{:discarded, run}`, which is what makes re-running a
  cascade over an already-cancelled subtree a no-op.

  `opts` accepts `serialization:` only, exactly as `fail/4` does.
  """
  @spec cancel(store :: Storage.t(), run_id :: run_id(), opts :: keyword()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  def cancel(%Storage{} = store, run_id, opts \\ []) do
    serialized(store, run_id, :cancel, opts, fn -> cancel_tail(store, run_id) end)
  end

  @spec cancel_tail(Storage.t(), run_id()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  defp cancel_tail(store, run_id) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        discarded(run_record, run_id, :cancel, :terminal_run)

      {:ok, run_record} ->
        with :ok <- Storage.update_run_status(store, run_id, :cancelled, failure: nil) do
          terminated(run_id, run_record.content_hash, :cancelled, nil)
          {:ok, Run.from_record(%{run_record | status: :cancelled, failure: nil})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancels every run linked to `parent_run_id` - for one invocation, or for
  all of them - and every run linked to those, recursively (ADR-0008
  decision 5).

  Retains: nothing is deleted and every position is left byte-identical;
  each run simply takes the `:cancelled` terminal status through `cancel/3`.

  Idempotent, and idempotent in the strong sense a crash needs. The walk
  descends into every child it finds, whatever that child's own status, and
  `cancel/3` discards a run that is already terminal - so a cascade
  interrupted halfway through a deep tree is completed correctly by
  re-running it, and a cascade over a subtree that is already fully
  cancelled writes nothing at all.

  There is no global transaction and there deliberately is none: each
  run's cancel is its own serialized write under its own run's exclusion
  (ADR-0004 decision 5), so a deep tree is O(subtree) writes. Cross-run
  locking is the only way to make it atomic, and this package does not have
  it and does not want it.

  Termination rests on the run tree being acyclic, which it is by
  construction: a child's run id strictly extends its parent's
  (`StatifierPersistence.Run.Linkage.child_run_id/3`), so no run can be its
  own descendant. This is why no depth ceiling is needed (ADR-0008
  decision 6).

  `metadata_match` is a `StatifierPersistence.Run.Linkage` containment map -
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
  # 5's retain semantics as a number: the runs the walk found already
  # terminal and left alone.
  @spec sweep(Storage.t(), Adapter.metadata(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp sweep(store, metadata_match, opts) do
    with {:ok, records} <- Storage.list_runs_by_metadata(store, metadata_match) do
      Enum.reduce_while(records, {:ok, {0, 0}}, &cascade_step(store, &1, opts, &2))
    end
  end

  # The match map is this package's own (`Run.Linkage.parent_match/1` or
  # `invocation_match/2`), so reading the two ids back out of it is
  # reading what this package just wrote. `invoke_id` is `nil` for the
  # whole-parent sweep, which is the contract's own value for it.
  @spec emit_cascade(Adapter.metadata(), non_neg_integer(), non_neg_integer()) :: :ok
  defp emit_cascade(metadata_match, cancelled, retained) do
    linkage = Map.get(metadata_match, Linkage.reserved_key(), %{})

    Telemetry.child_cascade_cancelled(cancelled, retained,
      parent_run_id: Map.get(linkage, "parent_run_id"),
      invoke_id: Map.get(linkage, "invoke_id")
    )
  end

  @spec cascade_step(
          Storage.t(),
          Adapter.run_record(),
          keyword(),
          {:ok, {non_neg_integer(), non_neg_integer()}}
        ) ::
          {:cont, {:ok, {non_neg_integer(), non_neg_integer()}}} | {:halt, {:error, error()}}
  defp cascade_step(store, record, opts, {:ok, {cancelled, retained}}) do
    case cancel_and_descend(store, record.run_id, opts) do
      {:ok, {node_cancelled, node_retained}} ->
        {:cont, {:ok, {cancelled + node_cancelled, retained + node_retained}}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  # The child is cancelled *before* the walk into its own children (the
  # moduledoc's ordering note): an interrupted cascade always leaves the
  # deepest still-active runs reachable from a run that is already
  # cancelled, which a re-run finds because the walk descends through
  # cancelled runs too - `cancel/3`'s own discard for an already-terminal
  # run stops nothing here, it only stops that one run's own count.
  @spec cancel_and_descend(Storage.t(), run_id(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp cancel_and_descend(store, run_id, opts) do
    with {:ok, {cancelled, retained}} <- cancel_counted(store, run_id, opts),
         {:ok, {sub_cancelled, sub_retained}} <-
           sweep(store, Linkage.parent_match(run_id), opts) do
      {:ok, {cancelled + sub_cancelled, retained + sub_retained}}
    end
  end

  @spec cancel_counted(Storage.t(), run_id(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, error()}
  defp cancel_counted(store, run_id, opts) do
    case cancel(store, run_id, opts) do
      {:ok, _run} -> {:ok, {1, 0}}
      {:discarded, _run} -> {:ok, {0, 1}}
      {:error, _reason} = error -> error
    end
  end

  # Runs `fun` - one entry point's whole fetch-to-persist tail - inside the
  # selected serialization strategy's `with_run/3` (ADR-0004 decision 5),
  # unwrapping the strategy's `{:ok, result}` envelope back to the tail's
  # own result. A strategy refusal (`{:error, {:serialization, _}}` from
  # the default over an adapter with no `lock_run/3`) surfaces unchanged.
  # Nothing inside any tail calls back into this function, so `with_run/3`
  # never nests on one run id.
  #
  # This is also the step seam (ADR-0009 decision 5): the one `:start` /
  # `:stop` pair this package emits brackets exactly this function, so the
  # upstream macrostep span - opened inside `fun` - nests inside it by
  # ordinary ambient context, and `st-ADR-0067` decision 5's "a span never
  # crosses a persist boundary" holds structurally rather than by
  # discipline. `[:statifier_persistence, :run, :lock]`'s `duration` is
  # the *wait*, which is why it is measured from before `with_run/3` to
  # the first line inside the body it runs rather than around the call:
  # the held time is the step, and the step already has a span.
  @spec serialized(Storage.t(), run_id(), entry(), keyword(), (-> result)) ::
          result | {:error, error()}
        when result: term()
  defp serialized(store, run_id, entry, opts, fun) do
    {strategy, config} = Keyword.get(opts, :serialization, {AdapterLock, store})
    span_ref = make_ref()
    started_at = Telemetry.run_step_start(run_id, entry, span_ref)
    lock_start = System.monotonic_time()

    locked =
      strategy.with_run(config, run_id, fn ->
        emit_lock(lock_start, run_id, strategy, :acquired, nil)
        fun.()
      end)

    result = unlocked(locked, lock_start, run_id, strategy)
    Telemetry.run_step_stop(started_at, step_stop_fields(run_id, entry, span_ref, result))

    result
  end

  @spec unlocked({:ok, result} | {:error, term()}, integer(), run_id(), module()) ::
          result | {:error, error()}
        when result: term()
  defp unlocked({:ok, result}, _lock_start, _run_id, _strategy), do: result

  defp unlocked({:error, reason} = error, lock_start, run_id, strategy) do
    emit_lock(lock_start, run_id, strategy, :unavailable, reason)
    error
  end

  @spec emit_lock(integer(), run_id(), module(), :acquired | :unavailable, term()) :: :ok
  defp emit_lock(lock_start, run_id, strategy, outcome, reason) do
    Telemetry.run_lock(System.monotonic_time() - lock_start,
      run_id: run_id,
      strategy: strategy,
      outcome: outcome,
      reason: reason
    )
  end

  # The stop half's metadata, read off whichever of the four return shapes
  # the tail produced. `session_id` is `nil` wherever no position was
  # decoded (ADR-0009 decision 4's honest nil): a terminal-run discard
  # reads the run record only, and a lock or identity refusal never loads
  # at all. `status` is `nil` where the step reached no write - with the
  # one exception of `{:budget_exhausted, _}`, which reaches a `:failed`
  # write and *then* returns an error (`tail_result/5`).
  @spec step_stop_fields(run_id(), entry(), reference(), term()) :: keyword()
  defp step_stop_fields(run_id, entry, span_ref, result) do
    {session_id, content_hash, outcome, status, reason} = stop_shape(result)

    [
      run_id: run_id,
      session_id: session_id,
      content_hash: content_hash,
      entry: entry,
      outcome: outcome,
      status: status,
      reason: reason,
      span_ref: span_ref
    ]
  end

  @spec stop_shape(term()) ::
          {String.t() | nil, String.t() | nil, :ok | :discarded | :error,
           Adapter.run_status() | nil, term()}
  defp stop_shape({:ok, %Run{} = run, %MachineState{} = machine_state}),
    do: {session_id(machine_state), run.content_hash, :ok, run.status, nil}

  defp stop_shape({:ok, %Run{} = run}), do: {nil, run.content_hash, :ok, run.status, nil}

  defp stop_shape({:discarded, %Run{} = run}),
    do: {nil, run.content_hash, :discarded, run.status, nil}

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

  # `{:discarded, run}` with its event: the three ways a delivery becomes
  # a non-event are a closed vocabulary (`docs/telemetry.md`), and only
  # `:position_terminal` repairs anything.
  @spec discarded(Adapter.run_record(), run_id(), entry(), atom(), boolean()) ::
          {:discarded, Run.t()}
  defp discarded(run_record, run_id, entry, reason, repaired? \\ false) do
    Telemetry.run_discarded(run_id: run_id, entry: entry, reason: reason, repaired?: repaired?)

    {:discarded, Run.from_record(run_record)}
  end

  @spec terminated(run_id(), String.t() | nil, Adapter.run_status(), String.t() | nil) :: :ok
  defp terminated(run_id, content_hash, status, reason) do
    Telemetry.run_terminated(
      run_id: run_id,
      session_id: nil,
      content_hash: content_hash,
      status: status,
      driven_by: :host,
      reason: reason
    )
  end

  @spec step_loaded(
          Storage.t(),
          run_id(),
          Adapter.run_record(),
          MachineState.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t(),
          entry()
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp step_loaded(store, run_id, run_record, machine_state, event, opts, executor, entry) do
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
      {:ok, event} -> stepped(store, run_id, machine_state, event, executor, entry)
      :discard -> discarded(run_record, run_id, entry, :builder_declined)
    end
  end

  @spec resolve_event(Event.t() | event_builder(), MachineState.t()) ::
          {:ok, Event.t()} | :discard
  defp resolve_event(%Event{} = event, _machine_state), do: {:ok, event}

  defp resolve_event(builder, machine_state) when is_function(builder, 1),
    do: builder.(machine_state)

  @spec stepped(Storage.t(), run_id(), MachineState.t(), Event.t(), Executor.t(), entry()) ::
          {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp stepped(store, run_id, machine_state, event, executor, entry) do
    case Interpreter.handle_event(machine_state, event) do
      {:ok, machine_state, effects} ->
        persist_tail(store, run_id, machine_state, effects, executor, :update)

      {:error, :not_running} ->
        repair_terminal(store, run_id, machine_state, entry)
    end
  end

  # The stored position went terminal without the run record catching up
  # (the record said `:active`, `handle_event/2` said `:not_running`).
  # Discard the event and repair the record's status: `:done` is the only
  # chart-driven terminal state (ADR-0004 decision 6), so the repaired
  # status is `:completed`. `position: :skip` carries the stored blob
  # forward untouched - nothing stepped.
  @spec repair_terminal(Storage.t(), run_id(), MachineState.t(), entry()) ::
          {:discarded, Run.t()} | {:error, error()}
  defp repair_terminal(store, run_id, machine_state, entry) do
    with :ok <- Storage.update_run(store, run_id, machine_state, :completed, position: :skip) do
      identity = Machine.identity(machine_state.machine)

      # Both events, because the repair is two facts at once: the delivery
      # became a non-event, and the record reached a terminal status on
      # this call. `driven_by: :chart` - the position was already terminal
      # because the chart put it there; no host asked for this.
      Telemetry.run_discarded(
        run_id: run_id,
        entry: entry,
        reason: :position_terminal,
        repaired?: true
      )

      Telemetry.run_terminated(
        run_id: run_id,
        session_id: session_id(machine_state),
        content_hash: identity && identity.content_hash,
        status: :completed,
        driven_by: :chart,
        reason: nil
      )

      {:discarded, run(run_id, :completed, identity)}
    end
  end

  # The shared tail of `create/4` and `step/5`, in ADR-0004 decision 3's
  # order: partition `:done`/`:budget_exhausted` to the lifecycle and hand
  # everything else to the executor in list order, derive the run status,
  # assert quiescence, persist. The identity refusal runs first - the same
  # `:unidentified_chart` arm the facade's writers return - so no effect is
  # executed for a run that cannot be persisted at all.
  @spec persist_tail(
          Storage.t(),
          run_id(),
          MachineState.t(),
          [Statifier.Effect.t()],
          Executor.t(),
          {:insert, Adapter.metadata()} | :update
        ) :: {:ok, Run.t(), MachineState.t()} | {:error, error()}
  defp persist_tail(store, run_id, machine_state, effects, executor, write) do
    case Machine.identity(machine_state.machine) do
      nil ->
        Telemetry.identity_refused(
          run_id: run_id,
          session_id: session_id(machine_state),
          stage: :run,
          reason: :unidentified_chart
        )

        {:error, :unidentified_chart}

      identity ->
        {lifecycle, executable} = Enum.split_with(effects, &lifecycle_effect?/1)
        context = %{run_id: run_id, content_hash: identity.content_hash}
        seam = %{context: context, executor: executor, session_id: session_id(machine_state)}

        failures = execute_effects(executable, seam, :defer)

        {machine_state, lifecycle} = reenter_failures(machine_state, failures, seam, lifecycle)

        status = run_status(machine_state, lifecycle)
        :ok = assert_quiescent(machine_state, lifecycle)

        with :ok <- write_run(write, store, run_id, machine_state, status, lifecycle) do
          report_write(write, run_id, seam.session_id, identity, status, lifecycle)
          tail_result(run_id, status, identity, lifecycle, machine_state)
        end
    end
  end

  # The lifecycle events the persist tail owns, emitted only once the write
  # has actually landed: a create reports `[..., :run, :created]`, and any
  # write that reached a terminal status reports `[..., :run, :terminated]`
  # with `driven_by: :chart` - `fail/4` and `cancel/3` are the `:host`
  # ones and report their own.
  #
  # `child?` and `metadata?` are both read off the merged map rather than
  # plumbed: the reserved linkage key is what makes a run a child
  # (ADR-0008 decision 2), and what is left after dropping it is exactly
  # the host's own `metadata:` (ADR-0006 decision 1). Neither the map nor
  # any key of it is ever emitted - only the two booleans (ADR-0009
  # decision 7).
  @spec report_write(
          {:insert, Adapter.metadata()} | :update,
          run_id(),
          String.t() | nil,
          Identity.t(),
          Adapter.run_status(),
          [Statifier.Effect.t()]
        ) :: :ok
  defp report_write({:insert, metadata}, run_id, session_id, identity, status, lifecycle) do
    Telemetry.run_created(
      run_id: run_id,
      session_id: session_id,
      content_hash: identity.content_hash,
      child?: Map.has_key?(metadata, Linkage.reserved_key()),
      metadata?: map_size(Map.delete(metadata, Linkage.reserved_key())) > 0
    )

    report_termination(run_id, session_id, identity, status, lifecycle)
  end

  defp report_write(:update, run_id, session_id, identity, status, lifecycle),
    do: report_termination(run_id, session_id, identity, status, lifecycle)

  @spec report_termination(
          run_id(),
          String.t() | nil,
          Identity.t(),
          Adapter.run_status(),
          [Statifier.Effect.t()]
        ) :: :ok
  defp report_termination(_run_id, _session_id, _identity, :active, _lifecycle), do: :ok

  defp report_termination(run_id, session_id, identity, status, lifecycle) do
    Telemetry.run_terminated(
      run_id: run_id,
      session_id: session_id,
      content_hash: identity.content_hash,
      status: status,
      driven_by: :chart,
      reason: failure_string(lifecycle)
    )
  end

  # The persisted-run return: `{:ok, ...}` for a live or completed run,
  # `{:error, {:budget_exhausted, payload}}` AFTER the `:failed` record is
  # durable, so the caller sees both the state and the reason.
  @spec tail_result(
          run_id(),
          Adapter.run_status(),
          Identity.t(),
          [Statifier.Effect.t()],
          MachineState.t()
        ) :: {:ok, Run.t(), MachineState.t()} | {:error, error()}
  defp tail_result(run_id, status, identity, lifecycle, machine_state) do
    case budget_effect(lifecycle) do
      nil -> {:ok, run(run_id, status, identity, done_effect(lifecycle)), machine_state}
      %BudgetExhausted{} = payload -> {:error, {:budget_exhausted, payload}}
    end
  end

  # `{:done, %Done{donedata: donedata}}` is consumed into `:completed` status
  # (ADR-0004 decision 6) and, from ADR-0008 decision 3, also surfaced: a
  # durable subchart's parent is answered with its child's donedata, and this
  # is the only moment it exists. It is deliberately not persisted - a
  # position that has reached a final state has no configuration left to
  # carry it, and inventing a column for it would make a run record a
  # result store. `nil` on every step that did not just complete the run -
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
  # observation must never steer a run. Effects the re-entries emit go
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
    case Interpreter.deliver_internal(
           machine_state,
           :platform,
           "error.communication",
           origin,
           opts
         ) do
      {:ok, machine_state, wave_effects} ->
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
      run_id: seam.context.run_id,
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

  # `:done` is the only path to `:completed` (ADR-0004 decision 6);
  # `:budget_exhausted` - from the primary pass or from a re-entry wave -
  # is the only chart-driven path to `:failed`.
  @spec run_status(MachineState.t(), [Statifier.Effect.t()]) :: Adapter.run_status()
  defp run_status(machine_state, lifecycle_effects) do
    cond do
      budget_exhausted?(lifecycle_effects) -> :failed
      machine_state.status == :done -> :completed
      true -> :active
    end
  end

  @spec budget_exhausted?([Statifier.Effect.t()]) :: boolean()
  defp budget_exhausted?(lifecycle_effects),
    do: Enum.any?(lifecycle_effects, &match?({:budget_exhausted, _payload}, &1))

  # The run record's short `failure` string - psql-console readable, not
  # an inspect dump (ADR-0004 decision 1) - and the same string
  # `[:statifier_persistence, :run, :terminated]` reports as `reason`, so
  # the event and the row can never disagree.
  @spec failure_string([Statifier.Effect.t()]) :: String.t() | nil
  defp failure_string(lifecycle_effects) do
    case budget_effect(lifecycle_effects) do
      nil -> nil
      %BudgetExhausted{budget: budget} -> "budget_exhausted: #{budget} rounds"
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
  @spec write_run(
          {:insert, Adapter.metadata()} | :update,
          Storage.t(),
          run_id(),
          MachineState.t(),
          Adapter.run_status(),
          [Statifier.Effect.t()]
        ) :: :ok | {:error, error()}
  defp write_run(write, store, run_id, machine_state, status, lifecycle_effects) do
    position = if budget_exhausted?(lifecycle_effects), do: :skip, else: :persist
    opts = [position: position, failure: failure_string(lifecycle_effects)]

    case write do
      {:insert, metadata} ->
        Storage.insert_run(store, run_id, machine_state, status, [{:metadata, metadata} | opts])

      :update ->
        Storage.update_run(store, run_id, machine_state, status, opts)
    end
  end

  @spec run(run_id(), Adapter.run_status(), Identity.t(), term()) :: Run.t()
  defp run(run_id, status, identity, donedata \\ nil) do
    %Run{
      run_id: run_id,
      status: status,
      content_hash: identity.content_hash,
      failure: nil,
      donedata: donedata
    }
  end
end
