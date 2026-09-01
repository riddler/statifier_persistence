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
    Invoke,
    Send,
    SendDelayed
  }

  alias Statifier.Machine.Identity
  alias StatifierPersistence.{Executor, Run, Storage}
  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage.Adapter

  @typedoc "A run's caller-supplied opaque key (ADR-0004 decision 2)."
  @type run_id :: Adapter.run_id()

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
  """
  @type opt ::
          {:executor, Executor.t()}
          | {:routes, MachineState.routes()}
          | {:invoke_types, MachineState.invoke_types()}
          | {:initialize, keyword()}
          | {:serialization, {module(), term()}}
          | {:metadata, Adapter.metadata()}

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
    with :ok <- Storage.check_metadata(store, Keyword.take(opts, [:metadata])) do
      {machine_state, effects} =
        Interpreter.initialize(machine, Keyword.get(opts, :initialize, []))

      serialized(store, run_id, opts, fn ->
        persist_tail(store, run_id, machine_state, effects, executor, {:insert, metadata(opts)})
      end)
    end
  end

  @spec metadata([opt()]) :: Adapter.metadata()
  defp metadata(opts), do: Keyword.get(opts, :metadata, %{})

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

    serialized(store, run_id, opts, fn ->
      step_tail(store, run_id, machine, event, opts, executor)
    end)
  end

  @spec step_tail(
          Storage.t(),
          run_id(),
          Machine.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t()
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp step_tail(store, run_id, machine, event, opts, executor) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        {:discarded, Run.from_record(run_record)}

      {:ok, run_record} ->
        with {:ok, machine_state} <- Storage.load_run_position(store, run_id, machine) do
          step_loaded(store, run_id, run_record, machine_state, event, opts, executor)
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
    serialized(store, run_id, opts, fn ->
      fail_tail(store, run_id, reason)
    end)
  end

  @spec fail_tail(Storage.t(), run_id(), String.t()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  defp fail_tail(store, run_id, reason) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        {:discarded, Run.from_record(run_record)}

      {:ok, run_record} ->
        with :ok <- Storage.update_run_status(store, run_id, :failed, failure: reason) do
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
    serialized(store, run_id, opts, fn -> cancel_tail(store, run_id) end)
  end

  @spec cancel_tail(Storage.t(), run_id()) ::
          {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
  defp cancel_tail(store, run_id) do
    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed, :cancelled] ->
        {:discarded, Run.from_record(run_record)}

      {:ok, run_record} ->
        with :ok <- Storage.update_run_status(store, run_id, :cancelled, failure: nil) do
          {:ok, Run.from_record(%{run_record | status: :cancelled, failure: nil})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Runs `fun` - one entry point's whole fetch-to-persist tail - inside the
  # selected serialization strategy's `with_run/3` (ADR-0004 decision 5),
  # unwrapping the strategy's `{:ok, result}` envelope back to the tail's
  # own result. A strategy refusal (`{:error, {:serialization, _}}` from
  # the default over an adapter with no `lock_run/3`) surfaces unchanged.
  # Nothing inside any tail calls back into this function, so `with_run/3`
  # never nests on one run id.
  @spec serialized(Storage.t(), run_id(), keyword(), (-> result)) ::
          result | {:error, error()}
        when result: term()
  defp serialized(store, run_id, opts, fun) do
    {strategy, config} = Keyword.get(opts, :serialization, {AdapterLock, store})

    case strategy.with_run(config, run_id, fun) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  @spec step_loaded(
          Storage.t(),
          run_id(),
          Adapter.run_record(),
          MachineState.t(),
          Event.t() | event_builder(),
          [opt()],
          Executor.t()
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp step_loaded(store, run_id, run_record, machine_state, event, opts, executor) do
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
      {:ok, event} -> stepped(store, run_id, machine_state, event, executor)
      :discard -> {:discarded, Run.from_record(run_record)}
    end
  end

  @spec resolve_event(Event.t() | event_builder(), MachineState.t()) ::
          {:ok, Event.t()} | :discard
  defp resolve_event(%Event{} = event, _machine_state), do: {:ok, event}

  defp resolve_event(builder, machine_state) when is_function(builder, 1),
    do: builder.(machine_state)

  @spec stepped(Storage.t(), run_id(), MachineState.t(), Event.t(), Executor.t()) ::
          {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp stepped(store, run_id, machine_state, event, executor) do
    case Interpreter.handle_event(machine_state, event) do
      {:ok, machine_state, effects} ->
        persist_tail(store, run_id, machine_state, effects, executor, :update)

      {:error, :not_running} ->
        repair_terminal(store, run_id, machine_state)
    end
  end

  # The stored position went terminal without the run record catching up
  # (the record said `:active`, `handle_event/2` said `:not_running`).
  # Discard the event and repair the record's status: `:done` is the only
  # chart-driven terminal state (ADR-0004 decision 6), so the repaired
  # status is `:completed`. `position: :skip` carries the stored blob
  # forward untouched - nothing stepped.
  @spec repair_terminal(Storage.t(), run_id(), MachineState.t()) ::
          {:discarded, Run.t()} | {:error, error()}
  defp repair_terminal(store, run_id, machine_state) do
    with :ok <- Storage.update_run(store, run_id, machine_state, :completed, position: :skip) do
      {:discarded, run(run_id, :completed, Machine.identity(machine_state.machine))}
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
        {:error, :unidentified_chart}

      identity ->
        {lifecycle, executable} = Enum.split_with(effects, &lifecycle_effect?/1)
        context = %{run_id: run_id, content_hash: identity.content_hash}

        failures = execute_effects(executable, executor, context)

        {machine_state, lifecycle} =
          reenter_failures(machine_state, failures, executor, context, lifecycle)

        status = run_status(machine_state, lifecycle)
        :ok = assert_quiescent(machine_state, lifecycle)

        with :ok <- write_run(write, store, run_id, machine_state, status, lifecycle) do
          tail_result(run_id, status, identity, lifecycle, machine_state)
        end
    end
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
      nil -> {:ok, run(run_id, status, identity), machine_state}
      %BudgetExhausted{} = payload -> {:error, {:budget_exhausted, payload}}
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
  @spec reenter_failures(
          MachineState.t(),
          [{Statifier.Effect.t(), term()}],
          Executor.t(),
          Executor.context(),
          [Statifier.Effect.t()]
        ) :: {MachineState.t(), [Statifier.Effect.t()]}
  defp reenter_failures(machine_state, failures, executor, context, lifecycle) do
    if budget_exhausted?(lifecycle) do
      {machine_state, lifecycle}
    else
      Enum.reduce_while(failures, {machine_state, lifecycle}, fn {effect, _reason}, acc ->
        reenter_one(effect, acc, executor, context)
      end)
    end
  end

  @spec reenter_one(
          Statifier.Effect.t(),
          {MachineState.t(), [Statifier.Effect.t()]},
          Executor.t(),
          Executor.context()
        ) :: {:cont | :halt, {MachineState.t(), [Statifier.Effect.t()]}}
  defp reenter_one(effect, {_machine_state, _lifecycle} = acc, executor, context) do
    case reentry_origin(effect) do
      :observational -> {:cont, acc}
      {origin, opts} -> deliver_reentry(acc, origin, opts, executor, context)
    end
  end

  @spec deliver_reentry(
          {MachineState.t(), [Statifier.Effect.t()]},
          Statifier.Event.Cause.origin(),
          keyword(),
          Executor.t(),
          Executor.context()
        ) :: {:cont | :halt, {MachineState.t(), [Statifier.Effect.t()]}}
  defp deliver_reentry({machine_state, lifecycle} = acc, origin, opts, executor, context) do
    case Interpreter.deliver_internal(
           machine_state,
           :platform,
           "error.communication",
           origin,
           opts
         ) do
      {:ok, machine_state, wave_effects} ->
        {wave_lifecycle, wave_executable} = Enum.split_with(wave_effects, &lifecycle_effect?/1)

        # Single wave: these failures are dropped, never re-entered.
        _wave_failures = execute_effects(wave_executable, executor, context)

        lifecycle = lifecycle ++ wave_lifecycle
        flow = if budget_exhausted?(wave_lifecycle), do: :halt, else: :cont
        {flow, {machine_state, lifecycle}}

      {:error, :not_running} ->
        {:halt, acc}
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

  @spec execute_effects([Statifier.Effect.t()], Executor.t(), Executor.context()) ::
          [{Statifier.Effect.t(), term()}]
  defp execute_effects(effects, executor, context) do
    effects
    |> Enum.reduce([], fn effect, failures ->
      case Executor.run(executor, effect, context) do
        :ok -> failures
        {:error, reason} -> [{effect, reason} | failures]
      end
    end)
    |> Enum.reverse()
  end

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
    {position, failure} =
      case budget_effect(lifecycle_effects) do
        nil -> {:persist, nil}
        %BudgetExhausted{budget: budget} -> {:skip, "budget_exhausted: #{budget} rounds"}
      end

    opts = [position: position, failure: failure]

    case write do
      {:insert, metadata} ->
        Storage.insert_run(store, run_id, machine_state, status, [{:metadata, metadata} | opts])

      :update ->
        Storage.update_run(store, run_id, machine_state, status, opts)
    end
  end

  @spec run(run_id(), Adapter.run_status(), Identity.t()) :: Run.t()
  defp run(run_id, status, identity) do
    %Run{
      run_id: run_id,
      status: status,
      content_hash: identity.content_hash,
      failure: nil
    }
  end
end
