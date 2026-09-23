defmodule StatifierPersistence.Migration.Transform do
  @moduledoc false
  # The pure half of `StatifierPersistence.Executions.migrate/4`: the
  # validation against the execution and the transform of its export
  # (ADR-0013 decisions 2, 3 and 6). It reads a position export, a plan and
  # the two machines, and writes nothing: every check and the whole
  # transform complete here, before `migrate/4` makes its one write
  # (decision 4). It also answers decision 6's static question - which
  # states of the from chart could own a timer, and which of those a plan
  # leaves unmapped or drops - which `migrate/4` asks before it reads the
  # execution.

  alias Statifier.{Machine, MachineState, Position}
  alias Statifier.Machine.Content.{Foreach, If, Send}
  alias StatifierPersistence.Executions
  alias StatifierPersistence.Migration.Plan

  @typep mapped :: {:ok, Plan.state_id()} | :dropped | :unmapped

  # What a clean transform answers: the position rebuilt on the to machine,
  # and the dropped states that were in the execution's configuration.
  @typep applied :: %{machine_state: MachineState.t(), dropped: [Plan.state_id()]}

  # A state of the from chart named in a timer refusal: its id, or its
  # index when the chart gives it none.
  @typep timer_state :: Plan.state_id() | non_neg_integer()

  # What the host's pin sources counted for the one execution, under each
  # source module; `%{}` when they were not asked.
  @typep source_counts :: %{module() => %{atom() => non_neg_integer()}}

  @doc false
  @spec transform(MachineState.t(), Plan.t(), Machine.t(), Machine.t(), source_counts()) ::
          {:ok, applied()} | {:error, [Executions.migration_finding()]}
  def transform(
        %MachineState{} = machine_state,
        %Plan{} = plan,
        from_machine,
        to_machine,
        source_counts
      ) do
    case Position.export(machine_state) do
      {:ok, exported} -> transform_export(exported, plan, from_machine, to_machine, source_counts)
      {:error, reason} -> {:error, [{:not_exportable, reason}]}
    end
  end

  @spec transform_export(Position.exported(), Plan.t(), Machine.t(), Machine.t(), source_counts()) ::
          {:ok, applied()} | {:error, [Executions.migration_finding()]}
  defp transform_export(exported, plan, from_machine, to_machine, source_counts) do
    mapping = Map.merge(plan.states, plan.history)
    map_id = &map_state(&1, mapping, plan.drop, to_machine)

    {sets, set_findings} = map_sets(exported, map_id)
    {history, history_findings} = map_history_values(exported.history_values, map_id)

    {invocations, invocation_findings} =
      map_invocations(exported.active_invocations, plan.invocations, map_id, to_machine)

    {datamodel, datamodel_findings} = apply_datamodel(exported.datamodel, plan.datamodel)

    findings =
      set_findings ++
        history_findings ++
        invocation_findings ++
        datamodel_findings ++
        pending_timer_findings(plan, from_machine, to_machine, source_counts) ++
        configuration_findings(sets.configuration, to_machine)

    case findings do
      [] ->
        exported
        |> Map.merge(sets)
        |> Map.merge(%{
          history_values: history,
          active_invocations: invocations,
          datamodel: datamodel
        })
        |> import(to_machine, dropped(exported.configuration, map_id))

      findings ->
        {:error, findings}
    end
  end

  @spec import(Position.exported(), Machine.t(), [Plan.state_id()]) ::
          {:ok, applied()} | {:error, [Executions.migration_finding()]}
  defp import(transformed, to_machine, dropped) do
    case Position.import(to_machine, transformed) do
      {:ok, machine_state} -> {:ok, %{machine_state: machine_state, dropped: dropped}}
      {:error, reason} -> {:error, [{:import_refused, reason}]}
    end
  end

  # ADR-0013 decision 1: a named source maps where the plan says; a dropped
  # one is removed on purpose; any other maps to the to chart's state of the
  # same id when there is one, and is otherwise unmapped. `:states` and
  # `:history` share no source (the static validation refuses a repeat), so
  # one merged map answers both.
  @spec map_state(
          Plan.state_id(),
          %{Plan.state_id() => Plan.state_id()},
          [Plan.state_id()],
          Machine.t()
        ) :: mapped()
  defp map_state(id, mapping, drop, to_machine) do
    cond do
      id in drop -> :dropped
      Map.has_key?(mapping, id) -> {:ok, Map.fetch!(mapping, id)}
      Machine.index(to_machine, id) != :error -> {:ok, id}
      true -> :unmapped
    end
  end

  @spec map_sets(Position.exported(), (Plan.state_id() -> mapped())) ::
          {map(), [Executions.migration_finding()]}
  defp map_sets(exported, map_id) do
    fields = [:configuration, :entered_states, :states_to_invoke]

    Enum.reduce(fields, {%{}, []}, fn field, {sets, found} ->
      {set, set_found} = map_set(Map.fetch!(exported, field), field, map_id)
      {Map.put(sets, field, set), found ++ set_found}
    end)
  end

  # A dropped id leaves the set; an unmapped one is a finding naming the
  # field it was found in.
  @spec map_set(MapSet.t(Plan.state_id()), atom(), (Plan.state_id() -> mapped())) ::
          {MapSet.t(Plan.state_id()), [Executions.migration_finding()]}
  defp map_set(ids, field, map_id) do
    ids
    |> Enum.sort()
    |> Enum.reduce({MapSet.new(), []}, fn id, {set, found} ->
      case map_id.(id) do
        {:ok, target} -> {MapSet.put(set, target), found}
        :dropped -> {set, found}
        :unmapped -> {set, found ++ [{:unmapped_state, field, id}]}
      end
    end)
  end

  @spec map_history_values(
          %{Plan.state_id() => MapSet.t(Plan.state_id())},
          (Plan.state_id() -> mapped())
        ) :: {map(), [Executions.migration_finding()]}
  defp map_history_values(history_values, map_id) do
    history_values
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {history_id, recorded}, {history, found} ->
      {values, value_found} = map_set(recorded, :history_values, map_id)

      case map_id.(history_id) do
        {:ok, target} -> {Map.put(history, target, values), found ++ value_found}
        :dropped -> {history, found}
        :unmapped -> {history, found ++ [{:unmapped_state, :history_values, history_id}]}
      end
    end)
  end

  # ADR-0013 decision 3's invocation rules: every active invocation maps -
  # through `:invocations`, or to the same ordinal under its state's mapped
  # id - to a key whose ordinal is in range of that to state's `<invoke>`
  # children, and no two keys coincide. The invocation ids cross unchanged,
  # and that is decision 7's child rule: a live child reaches its parent by
  # its invocation id alone, so a transform that answers keeps every child
  # the parent named resolvable, and one that cannot is refused here.
  @spec map_invocations(
          %{{Plan.state_id(), non_neg_integer()} => String.t()},
          [Plan.invocation()],
          (Plan.state_id() -> mapped()),
          Machine.t()
        ) :: {map(), [Executions.migration_finding()]}
  defp map_invocations(active_invocations, moved, map_id, to_machine) do
    named = Map.new(moved, fn {s, o, t, p} -> {{s, o}, {t, p}} end)

    {pairs, found} =
      active_invocations
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {key, invoke_id}, {pairs, found} ->
        case map_invocation(key, named, map_id, to_machine) do
          {:ok, target} -> {pairs ++ [{key, target, invoke_id}], found}
          {:error, finding} -> {pairs, found ++ [finding]}
        end
      end)

    {Map.new(pairs, fn {_key, target, invoke_id} -> {target, invoke_id} end),
     found ++ coinciding(pairs)}
  end

  @spec map_invocation(
          {Plan.state_id(), non_neg_integer()},
          map(),
          (Plan.state_id() -> mapped()),
          Machine.t()
        ) :: {:ok, {Plan.state_id(), non_neg_integer()}} | {:error, term()}
  defp map_invocation({state_id, ordinal} = key, named, map_id, to_machine) do
    case Map.fetch(named, key) do
      {:ok, target} -> {:ok, target}
      :error -> default_invocation(key, map_id.(state_id), ordinal, to_machine)
    end
  end

  defp default_invocation(key, :dropped, _ordinal, _to_machine),
    do: {:error, {:invocation_dropped, key}}

  defp default_invocation(key, :unmapped, _ordinal, _to_machine),
    do: {:error, {:invocation_unmapped, key}}

  defp default_invocation(key, {:ok, target_id}, ordinal, to_machine) do
    {:ok, index} = Machine.index(to_machine, target_id)
    invoke_count = to_machine |> Machine.at(index) |> Map.fetch!(:invoke) |> length()

    if ordinal < invoke_count,
      do: {:ok, {target_id, ordinal}},
      else: {:error, {:invocation_out_of_range, key, {target_id, ordinal}, invoke_count}}
  end

  defp coinciding(pairs) do
    pairs
    |> Enum.group_by(fn {_key, target, _id} -> target end, fn {key, _target, _id} -> key end)
    |> Enum.filter(fn {_target, sources} -> length(sources) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {target, sources} -> {:invocations_coincide, target, Enum.sort(sources)} end)
  end

  # ADR-0013 decision 3: the operations apply in order. A refused operation
  # is a finding and is skipped, so the operations after it are still
  # checked and every finding comes back in one answer.
  @spec apply_datamodel(map(), [Plan.datamodel_op()]) ::
          {map(), [Executions.migration_finding()]}
  defp apply_datamodel(datamodel, ops) do
    ops
    |> Enum.with_index()
    |> Enum.reduce({datamodel, []}, fn {op, index}, {model, found} ->
      case apply_op(model, op) do
        {:ok, model} -> {model, found}
        {:error, why} -> {model, found ++ [{:datamodel_refused, index, op, why}]}
      end
    end)
  end

  defp apply_op(model, {:add, key, value}) do
    if Map.has_key?(model, key),
      do: {:error, :key_present},
      else: {:ok, Map.put(model, key, value)}
  end

  defp apply_op(model, {:rename, from, to}) do
    cond do
      not Map.has_key?(model, from) -> {:error, :key_absent}
      Map.has_key?(model, to) -> {:error, :key_present}
      true -> {:ok, model |> Map.delete(from) |> Map.put(to, Map.fetch!(model, from))}
    end
  end

  defp apply_op(model, {:remove, key}) do
    if Map.has_key?(model, key), do: {:ok, Map.delete(model, key)}, else: {:error, :key_absent}
  end

  # ADR-0013 decision 6, the half that depends on the execution: a plan
  # that leaves a state that could own a timer unmapped, while any source
  # counts a pending timer for the execution, is refused unless the plan
  # drops that state. A count names no state and no send id, so any
  # non-zero count from any source is a pending timer the unmapped states
  # could own.
  @spec pending_timer_findings(Plan.t(), Machine.t(), Machine.t(), source_counts()) ::
          [Executions.migration_finding()]
  defp pending_timer_findings(plan, from_machine, to_machine, source_counts) do
    %{unmapped: unmapped} = timer_states(plan, from_machine, to_machine)

    if unmapped != [] and pending?(source_counts),
      do: [{:pending_timers, unmapped, source_counts}],
      else: []
  end

  defp pending?(source_counts) do
    Enum.any?(source_counts, fn {_source, counts} ->
      Enum.any?(counts, fn {_name, count} -> count > 0 end)
    end)
  end

  @doc false
  # ADR-0013 decision 6's static question, answered over the plan and the
  # two machines alone: the states of the from chart that could own a
  # timer and that the plan leaves unmapped, and those it drops. A state
  # with no id cannot be named by a plan and has no same-id counterpart, so
  # decision 1 leaves it unmapped; it is named by its index.
  @spec timer_states(Plan.t(), Machine.t(), Machine.t()) :: %{
          unmapped: [timer_state()],
          dropped: [timer_state()]
        }
  def timer_states(%Plan{} = plan, %Machine{} = from_machine, %Machine{} = to_machine) do
    mapping = Map.merge(plan.states, plan.history)

    grouped =
      from_machine
      |> timer_owners()
      |> Enum.group_by(fn
        index when is_integer(index) -> :unmapped
        id -> map_state(id, mapping, plan.drop, to_machine)
      end)

    %{unmapped: Map.get(grouped, :unmapped, []), dropped: Map.get(grouped, :dropped, [])}
  end

  @doc false
  # ADR-0013 decision 6's definition, static over the from chart: a state
  # could own a timer when a `<send>` with a `delay` or a `delayexpr` - both
  # compile to a non-nil `delay` - appears in its `onentry`, its `onexit`,
  # the content of a transition it owns (its `<initial>` element's and a
  # history state's default transition included), or the `<finalize>` of
  # any of its `<invoke>`s, the bodies of nested `<if>` and `<foreach>`
  # included. Answers the ids of those states, and the indexes of any that
  # have no id, sorted.
  @spec timer_owners(Machine.t()) :: [timer_state()]
  def timer_owners(%Machine{states: states} = machine) do
    states
    |> Tuple.to_list()
    |> Enum.filter(&owns_delayed_send?(machine, &1))
    |> Enum.map(fn state -> state.id || state.index end)
    |> Enum.sort()
  end

  defp owns_delayed_send?(machine, state) do
    transitions =
      [state.initial_transition, state.history_default | state.transitions]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&Machine.transition(machine, &1).content)

    blocks =
      Enum.map(state.onentry ++ state.onexit, & &1.content) ++
        for(%{finalize: %{content: content}} <- state.invoke, do: content)

    Enum.any?(transitions ++ blocks, &delayed_send_in?(machine, &1))
  end

  defp delayed_send_in?(machine, c_indexes) do
    Enum.any?(c_indexes, fn c_index ->
      case Machine.content(machine, c_index) do
        %Send{delay: delay} -> delay != nil
        %If{branches: branches} -> Enum.any?(branches, &delayed_send_in?(machine, &1.content))
        %Foreach{content: content} -> delayed_send_in?(machine, content)
        _other -> false
      end
    end)
  end

  # ADR-0013's 2026-09-23 Amendment, finding 3: the transformed
  # configuration, resolved in the to machine with the root added, must be
  # a legal configuration (SCXML 3.11). Resolving every id is not enough: a
  # dropped active leaf leaves its compound parent with no active child,
  # which `Position.import/2` accepts. The finding names the transformed
  # configuration, sorted, whatever else the pass found beside it.
  @spec configuration_findings(MapSet.t(Plan.state_id()), Machine.t()) ::
          [Executions.migration_finding()]
  defp configuration_findings(configuration, to_machine) do
    if legal_configuration?(configuration, to_machine),
      do: [],
      else: [{:illegal_configuration, Enum.sort(configuration)}]
  end

  # The legality rule, and no further: every compound state in the set
  # (the root included) has exactly one child state in it, every parallel
  # state has every child state in it, every atomic state has every proper
  # ancestor in it, and no history pseudo-state is in it. It uses only
  # public `Statifier.Machine` functions and never the engine's position
  # predicate. An id that does not resolve is left to `Position.import/2`,
  # which names it.
  @spec legal_configuration?(MapSet.t(Plan.state_id()), Machine.t()) :: boolean()
  defp legal_configuration?(configuration, machine) do
    indexes =
      for id <- configuration,
          {:ok, index} <- [Machine.index(machine, id)],
          into: MapSet.new([0]) do
        index
      end

    Enum.all?(indexes, &legal_at?(machine, &1, indexes))
  end

  defp legal_at?(machine, index, indexes) do
    cond do
      Machine.history?(machine, index) ->
        false

      Machine.atomic?(machine, index) ->
        machine |> Machine.proper_ancestors(index) |> Enum.all?(&MapSet.member?(indexes, &1))

      Machine.parallel?(machine, index) ->
        machine |> Machine.child_states(index) |> Enum.all?(&MapSet.member?(indexes, &1))

      true ->
        machine |> Machine.child_states(index) |> Enum.count(&MapSet.member?(indexes, &1)) == 1
    end
  end

  defp dropped(configuration, map_id) do
    configuration |> Enum.filter(&(map_id.(&1) == :dropped)) |> Enum.sort()
  end
end
