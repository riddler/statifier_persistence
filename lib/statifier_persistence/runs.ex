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

  Two Phase 3 boundaries, both lifted by later phases of this bead's plan:
  this module documents no concurrency guarantee yet (per-run serialization
  arrives as a pluggable strategy, ADR-0004 decision 5), and executor
  `{:error, _}` results are collected but not yet re-entered as
  `error.communication` events (ADR-0004 decision 4).
  """

  alias Statifier.{Event, Interpreter, Machine, MachineState}
  alias Statifier.Machine.Identity
  alias StatifierPersistence.{Executor, Run, Storage}
  alias StatifierPersistence.Storage.Adapter

  @typedoc "A run's caller-supplied opaque key (ADR-0004 decision 2)."
  @type run_id :: Adapter.run_id()

  @typedoc "This module's error vocabulary: the facade's arms, unflattened."
  @type error :: Storage.error()

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
  """
  @type opt ::
          {:executor, Executor.t()}
          | {:routes, MachineState.routes()}
          | {:invoke_types, MachineState.invoke_types()}
          | {:initialize, keyword()}

  @doc """
  Creates a run: `Statifier.Interpreter.initialize/2` (which cannot fail),
  then the shared persist tail - effects through the executor seam,
  `:done`/`:budget_exhausted` consumed into run status, quiescence
  asserted, the record inserted with its encoded position.

  Create-exactly-once rests on the adapter's atomic `:run_exists` refusal
  (ADR-0004 decision 2), not on a pre-check here: creating an existing
  `run_id` returns `{:error, :run_exists}`.
  """
  @spec create(store :: Storage.t(), run_id :: run_id(), machine :: Machine.t(), opts :: [opt()]) ::
          {:ok, Run.t(), MachineState.t()} | {:error, error()}
  def create(%Storage{} = store, run_id, %Machine{} = machine, opts) do
    executor = Keyword.fetch!(opts, :executor)

    {machine_state, effects} =
      Interpreter.initialize(machine, Keyword.get(opts, :initialize, []))

    persist_tail(store, run_id, machine_state, effects, executor, :insert)
  end

  @doc """
  Delivers one external event to a run, in ADR-0004 decision 3's order (the
  moduledoc quotes it).

  An event delivered to a terminal run returns `{:discarded, run}` from the
  run record alone, before any position decode. `handle_event/2`'s
  `{:error, :not_running}` arm is the structural backstop for a run record
  whose `:active` status lies about a terminal stored position: it discards
  too, and repairs the record's status to `:completed` on the way out.
  """
  @spec step(
          store :: Storage.t(),
          run_id :: run_id(),
          machine :: Machine.t(),
          event :: Event.t(),
          opts :: [opt()]
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  def step(%Storage{} = store, run_id, %Machine{} = machine, %Event{} = event, opts) do
    executor = Keyword.fetch!(opts, :executor)

    case Storage.fetch_run(store, run_id) do
      {:ok, %{status: status} = run_record} when status in [:completed, :failed] ->
        {:discarded, Run.from_record(run_record)}

      {:ok, _run_record} ->
        with {:ok, machine_state} <- Storage.load_run_position(store, run_id, machine) do
          step_loaded(store, run_id, machine_state, event, opts, executor)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec step_loaded(
          Storage.t(),
          run_id(),
          MachineState.t(),
          Event.t(),
          [opt()],
          Executor.t()
        ) :: {:ok, Run.t(), MachineState.t()} | {:discarded, Run.t()} | {:error, error()}
  defp step_loaded(store, run_id, machine_state, event, opts, executor) do
    # The bare match IS the st-ADR-0064 tripwire: `from_binary/2` blanks
    # both fields unconditionally on decode, so if upstream ever stops,
    # this fails loudly here rather than silently resuming a stale
    # snapshot downstream.
    %MachineState{routes: nil, invoke_types: nil} = machine_state

    machine_state =
      machine_state
      |> MachineState.put_routes(opts[:routes])
      |> MachineState.put_invoke_types(opts[:invoke_types])

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
          :insert | :update
        ) :: {:ok, Run.t(), MachineState.t()} | {:error, error()}
  defp persist_tail(store, run_id, machine_state, effects, executor, write) do
    case Machine.identity(machine_state.machine) do
      nil ->
        {:error, :unidentified_chart}

      identity ->
        {lifecycle, actionable} = Enum.split_with(effects, &lifecycle_effect?/1)
        context = %{run_id: run_id, content_hash: identity.content_hash}

        # Phase 3 of this bead's plan collects executor failures without
        # re-entry; error re-entry through `Interpreter.deliver_internal/5`
        # is the next phase (ADR-0004 decision 4).
        _failures = execute_effects(actionable, executor, context)

        status = run_status(machine_state, lifecycle)
        :ok = assert_quiescent(machine_state, lifecycle)

        with :ok <- write_run(write, store, run_id, machine_state, status, lifecycle) do
          {:ok, run(run_id, status, identity), machine_state}
        end
    end
  end

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

  # `:done` is the only path to `:completed` (ADR-0004 decision 6).
  # `:budget_exhausted` is handled minimally in Phase 3 of this bead's
  # plan - the run persists as `:failed` with its position untouched, and
  # the next phase owns the full semantics (failure reason, error return).
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
  # forward on update (ADR-0004 decision 1).
  @spec write_run(
          :insert | :update,
          Storage.t(),
          run_id(),
          MachineState.t(),
          Adapter.run_status(),
          [Statifier.Effect.t()]
        ) :: :ok | {:error, error()}
  defp write_run(write, store, run_id, machine_state, status, lifecycle_effects) do
    position = if budget_exhausted?(lifecycle_effects), do: :skip, else: :persist

    case write do
      :insert -> Storage.insert_run(store, run_id, machine_state, status, position: position)
      :update -> Storage.update_run(store, run_id, machine_state, status, position: position)
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
