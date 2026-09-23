defmodule StatifierPersistence.Migration.Plan do
  @moduledoc """
  A migration plan: how one execution's position crosses from one chart to
  another, as data.

  ADR-0013 (`docs/adr/0013-the-migration-plan.md`) decides the plan. This
  module implements its decision 1 (the plan's fields and its one map
  encoding) and the static half of its decision 3 (the validation against
  the two machines). It does not migrate anything and reads no execution;
  applying a plan to an execution is `Executions`' job, not this module's.

  This is the plan for moving an **execution** between charts. It has
  nothing to do with `StatifierPersistence.Ecto.Migrations`, the helper that
  creates and upgrades this package's tables.

  ## The fields

  A plan names the chart it moves from and the chart it moves to by content
  hash, and says how every part of a position crosses between them
  (ADR-0013 decision 1):

  - `:from` and `:to` - the two content hashes.
  - `:states` - a source state id to a target state id. A state the plan does
    not name maps to the state of the same id in the to chart, when there is
    one.
  - `:drop` - source state ids the plan removes on purpose.
  - `:history` - a source history state id to a target history state id,
    with the same default as `:states`.
  - `:invocations` - one `{from_state_id, from_ordinal, to_state_id,
    to_ordinal}` per moved invocation; the ordinal is the engine's
    within-state document-order ordinal of an `<invoke>`, counted from `0`.
  - `:timers` - `%{keep_mapped: true}`, the only value the format admits
    (ADR-0013 decision 6).
  - `:datamodel` - an ordered list of `{:add, key, value}`,
    `{:rename, from_key, to_key}` and `{:remove, key}` on top-level datamodel
    keys. A value is a JSON literal, never an expression, and a key that
    begins with `_` is refused because those are the engine's system
    variables.

  The struct is the in-memory form. What crosses a package boundary or
  reaches storage is the map form `to_map/1` writes and `from_map/1` reads:
  string keys only, an invocation as the four-element list
  `[from_state_id, from_ordinal, to_state_id, to_ordinal]`, and a datamodel
  operation as an object with an `"op"` key.

  ## An example

  A library hold waits in `awaiting_pickup` for `copy.collected` or
  `pickup.expired`. The library then renames that state `ready_for_pickup`
  and gives the routing step before it a `transferred` outcome leading to a
  new state. The plan that moves a waiting hold across that edit renames one
  state and adds one datamodel key:

      {:ok, plan} =
        Plan.new(
          from: from_hash,
          to: to_hash,
          states: %{"awaiting_pickup" => "ready_for_pickup"},
          datamodel: [{:add, "transfer_branch", nil}]
        )

      :ok = Plan.validate(plan, from_machine, to_machine)

  In the map form the same plan is:

      %{
        "from" => from_hash,
        "to" => to_hash,
        "states" => %{"awaiting_pickup" => "ready_for_pickup"},
        "drop" => [],
        "history" => %{},
        "invocations" => [],
        "timers" => %{"keep_mapped" => true},
        "datamodel" => [%{"op" => "add", "key" => "transfer_branch", "value" => nil}]
      }
  """

  alias Statifier.Machine
  alias Statifier.Machine.Identity

  @enforce_keys [:from, :to]
  defstruct [
    :from,
    :to,
    states: %{},
    drop: [],
    history: %{},
    invocations: [],
    timers: %{keep_mapped: true},
    datamodel: []
  ]

  @typedoc "An author-written state id."
  @type state_id :: String.t()

  @typedoc "A chart's content hash, as `Statifier.Machine.Identity` writes it."
  @type content_hash :: String.t()

  @typedoc "One moved invocation: `{from_state_id, from_ordinal, to_state_id, to_ordinal}`."
  @type invocation :: {state_id(), non_neg_integer(), state_id(), non_neg_integer()}

  @typedoc "A JSON literal: the only kind of value a datamodel operation carries."
  @type literal ::
          nil | boolean() | number() | String.t() | [literal()] | %{String.t() => literal()}

  @typedoc "One operation on a top-level datamodel key."
  @type datamodel_op ::
          {:add, String.t(), literal()}
          | {:rename, String.t(), String.t()}
          | {:remove, String.t()}

  @type t :: %__MODULE__{
          from: content_hash(),
          to: content_hash(),
          states: %{state_id() => state_id()},
          drop: [state_id()],
          history: %{state_id() => state_id()},
          invocations: [invocation()],
          timers: %{keep_mapped: true},
          datamodel: [datamodel_op()]
        }

  @typedoc "A plan field, or `:plan` for the plan as a whole."
  @type field ::
          :plan | :from | :to | :states | :drop | :history | :invocations | :timers | :datamodel

  @typedoc """
  Why `new/1` or `from_map/1` refused a plan: the field at fault and what is
  wrong with it.
  """
  @type malformed :: {:malformed_plan, field(), term()}

  @typedoc """
  One static finding. Each names the offending id.

  - `{:identity_mismatch, :from | :to, plan_hash, machine_hash}` - the
    machine does not carry the identity whose content hash the plan names;
    `machine_hash` is `nil` for a machine with no identity.
  - `{:unknown_source, field, state_id}` - a source id is not a state of the
    from chart.
  - `{:unknown_target, field, state_id}` - a target id is not a state of the
    to chart.
  - `{:duplicate_source, state_id}` - a source id appears more than once
    across `:states`, `:drop` and `:history`.
  - `{:history_mismatch, field, source_id, target_id}` - a history state is
    mapped to a state that is not a history state, or `:history` names a
    state that is not a history state.
  - `{:invocation_out_of_range, side, state_id, ordinal, invoke_count}` -
    the ordinal is not one of that state's `<invoke>` children; `side` is
    `:from` or `:to`.
  - `{:duplicate_invocation, :from | :to, {state_id, ordinal}}` - two moved
    invocations share a source, or share a target.
  """
  @type finding ::
          {:identity_mismatch, :from | :to, content_hash(), content_hash() | nil}
          | {:unknown_source, :states | :drop | :history | :invocations, state_id()}
          | {:unknown_target, :states | :history | :invocations, state_id()}
          | {:duplicate_source, state_id()}
          | {:history_mismatch, :states | :history, state_id(), state_id()}
          | {:invocation_out_of_range, :from | :to, state_id(), non_neg_integer(),
             non_neg_integer()}
          | {:duplicate_invocation, :from | :to, {state_id(), non_neg_integer()}}

  @fields [:from, :to, :states, :drop, :history, :invocations, :timers, :datamodel]
  @map_keys Enum.map(@fields, &Atom.to_string/1)

  @doc """
  Builds a plan from its fields, refusing a malformed one (ADR-0013
  decision 1).

  Takes a keyword list or a map with the struct's atom keys. `:from` and
  `:to` are required; every other field defaults to the empty plan's value
  (`:timers` to `%{keep_mapped: true}`). Answers
  `{:error, {:malformed_plan, field, reason}}` naming the first field at
  fault: an unknown key, a hash that is not a non-empty string, a state id
  that is not a non-empty string, an invocation that is not a four-tuple of
  ids and non-negative ordinals, a `:timers` other than
  `%{keep_mapped: true}`, a datamodel operation of another shape, a
  datamodel key that begins with `_`, or a datamodel value that is not a
  JSON literal.

  A plan `new/1` answers is well-formed, not valid: whether its ids name
  states of the two charts is `validate/3`'s question.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, malformed()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: malformed(:plan, :not_a_keyword_list_or_map)
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- known_keys(attrs, @fields),
         {:ok, from} <- hash(attrs, :from),
         {:ok, to} <- hash(attrs, :to),
         {:ok, states} <- id_map(attrs, :states),
         {:ok, drop} <- id_list(attrs, :drop),
         {:ok, history} <- id_map(attrs, :history),
         {:ok, invocations} <- invocations(attrs),
         {:ok, timers} <- timers(attrs),
         {:ok, datamodel} <- datamodel(attrs) do
      {:ok,
       %__MODULE__{
         from: from,
         to: to,
         states: states,
         drop: drop,
         history: history,
         invocations: invocations,
         timers: timers,
         datamodel: datamodel
       }}
    end
  end

  def new(_attrs), do: malformed(:plan, :not_a_keyword_list_or_map)

  @doc """
  Writes a plan in its map form: the one encoding of a plan (ADR-0013
  decision 1).

  Every key is a string and every value is JSON-safe: an invocation is the
  list `[from_state_id, from_ordinal, to_state_id, to_ordinal]` and a
  datamodel operation is an object whose `"op"` is `"add"`, `"rename"` or
  `"remove"`. Every field is written, defaults included, so
  `from_map(to_map(plan))` answers `{:ok, plan}`.
  """
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = plan) do
    %{
      "from" => plan.from,
      "to" => plan.to,
      "states" => plan.states,
      "drop" => plan.drop,
      "history" => plan.history,
      "invocations" => Enum.map(plan.invocations, &Tuple.to_list/1),
      "timers" => %{"keep_mapped" => plan.timers.keep_mapped},
      "datamodel" => Enum.map(plan.datamodel, &op_to_map/1)
    }
  end

  @doc """
  Reads a plan from its map form (ADR-0013 decision 1), refusing a
  malformed one exactly as `new/1` does.

  Keys are strings only; an atom key is an unknown key. `"from"` and `"to"`
  are required and every other key defaults as in `new/1`. The input is
  what a JSON decoder answers, so a plan a host stored as JSON reads back
  unchanged.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, malformed()}
  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- known_keys(map, @map_keys) do
      map
      |> Enum.map(fn {key, value} -> decode_field(key, value) end)
      |> new()
    end
  end

  def from_map(_map), do: malformed(:plan, :not_a_map)

  @doc """
  The static validation: checks a plan against the two compiled machines,
  before any execution is read (ADR-0013 decision 3, its first half).

  Answers `:ok`, or `{:error, findings}` with **every** finding at once,
  never only the first; `t:finding/0` lists them. The checks are: each
  machine carries the identity whose content hash the plan names; every
  source id in `:states`, `:drop`, `:history` and `:invocations` is a state
  of the from chart; every target id is a state of the to chart; no source
  id appears twice across `:states`, `:drop` and `:history`; a history state
  maps only to a history state, and `:history` names only history states;
  every invocation's from ordinal is in range of its from state's `<invoke>`
  children and its to ordinal in range of its to state's; and no two
  invocations share a source or a target.

  It reads the two machines through `Statifier.Machine`'s accessors and
  nothing else: it runs no interpreter and reads no position. Whether an
  execution's states are all mapped is the second validation's question,
  asked at apply.
  """
  @spec validate(t(), Machine.t(), Machine.t()) :: :ok | {:error, [finding()]}
  def validate(%__MODULE__{} = plan, %Machine{} = from_machine, %Machine{} = to_machine) do
    findings =
      identity_findings(:from, plan.from, from_machine) ++
        identity_findings(:to, plan.to, to_machine) ++
        mapping_findings(:states, plan.states, from_machine, to_machine) ++
        drop_findings(plan.drop, from_machine) ++
        mapping_findings(:history, plan.history, from_machine, to_machine) ++
        duplicate_source_findings(plan) ++
        invocation_findings(plan.invocations, from_machine, to_machine)

    case findings do
      [] -> :ok
      findings -> {:error, findings}
    end
  end

  # -- new/1 field checks ---------------------------------------------------

  defp known_keys(attrs, allowed) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] -> :ok
      unknown -> malformed(:plan, {:unknown_keys, Enum.sort(unknown)})
    end
  end

  defp hash(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> malformed(field, {:invalid, value})
      :error -> malformed(field, :missing)
    end
  end

  defp id_map(attrs, field) do
    case Map.get(attrs, field, %{}) do
      value when is_map(value) and not is_struct(value) -> every(value, field, &id_pair?/1)
      value -> malformed(field, {:not_a_map, value})
    end
  end

  defp id_list(attrs, field) do
    case Map.get(attrs, field, []) do
      value when is_list(value) -> every(value, field, &id?/1)
      value -> malformed(field, {:not_a_list, value})
    end
  end

  defp invocations(attrs) do
    case Map.get(attrs, :invocations, []) do
      value when is_list(value) -> every(value, :invocations, &invocation?/1)
      value -> malformed(:invocations, {:not_a_list, value})
    end
  end

  # Answers the collection when every entry passes, or names the first that
  # does not.
  defp every(value, field, ok?) do
    case Enum.find(value, &(not ok?.(&1))) do
      nil -> {:ok, value}
      entry -> malformed(field, {:invalid_entry, entry})
    end
  end

  defp id_pair?({source, target}), do: id?(source) and id?(target)

  defp invocation?({from_id, from_ordinal, to_id, to_ordinal}),
    do: id?(from_id) and ordinal?(from_ordinal) and id?(to_id) and ordinal?(to_ordinal)

  defp invocation?(_entry), do: false

  defp timers(attrs) do
    case Map.get(attrs, :timers, %{keep_mapped: true}) do
      %{keep_mapped: true} = timers when map_size(timers) == 1 -> {:ok, timers}
      value -> malformed(:timers, {:invalid, value})
    end
  end

  defp datamodel(attrs) do
    case Map.get(attrs, :datamodel, []) do
      ops when is_list(ops) ->
        ops
        |> Enum.with_index()
        |> Enum.find_value({:ok, ops}, fn {op, index} -> op_fault(op, index) end)

      value ->
        malformed(:datamodel, {:not_a_list, value})
    end
  end

  defp op_fault({:add, key, value}, index) do
    key_fault(key, index) ||
      if literal?(value), do: nil, else: malformed(:datamodel, {:not_a_literal, index, value})
  end

  defp op_fault({:rename, from_key, to_key}, index),
    do: key_fault(from_key, index) || key_fault(to_key, index)

  defp op_fault({:remove, key}, index), do: key_fault(key, index)
  defp op_fault(op, index), do: malformed(:datamodel, {:invalid_operation, index, op})

  defp key_fault("_" <> _rest = key, index),
    do: malformed(:datamodel, {:system_variable, index, key})

  defp key_fault(key, index) do
    if id?(key), do: nil, else: malformed(:datamodel, {:invalid_key, index, key})
  end

  defp literal?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp literal?(value) when is_binary(value), do: String.valid?(value)
  defp literal?(value) when is_list(value), do: Enum.all?(value, &literal?/1)

  defp literal?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and literal?(item) end)

  defp literal?(_value), do: false

  defp id?(value), do: is_binary(value) and value != ""
  defp ordinal?(value), do: is_integer(value) and value >= 0

  defp malformed(field, reason), do: {:error, {:malformed_plan, field, reason}}

  # -- the map form -----------------------------------------------------------

  defp op_to_map({:add, key, value}), do: %{"op" => "add", "key" => key, "value" => value}
  defp op_to_map({:rename, from, to}), do: %{"op" => "rename", "from" => from, "to" => to}
  defp op_to_map({:remove, key}), do: %{"op" => "remove", "key" => key}

  # A value of the wrong shape is passed through unchanged, so new/1 refuses
  # it and names the field.
  defp decode_field("invocations", entries) when is_list(entries),
    do: {:invocations, Enum.map(entries, &decode_invocation/1)}

  defp decode_field("timers", %{"keep_mapped" => keep} = timers) when map_size(timers) == 1,
    do: {:timers, %{keep_mapped: keep}}

  defp decode_field("datamodel", ops) when is_list(ops),
    do: {:datamodel, Enum.map(ops, &decode_op/1)}

  defp decode_field(key, value), do: {String.to_existing_atom(key), value}

  defp decode_invocation([from_id, from_ordinal, to_id, to_ordinal]),
    do: {from_id, from_ordinal, to_id, to_ordinal}

  defp decode_invocation(entry), do: entry

  defp decode_op(%{"op" => "add", "key" => key, "value" => value} = op) when map_size(op) == 3,
    do: {:add, key, value}

  defp decode_op(%{"op" => "rename", "from" => from, "to" => to} = op) when map_size(op) == 3,
    do: {:rename, from, to}

  defp decode_op(%{"op" => "remove", "key" => key} = op) when map_size(op) == 2,
    do: {:remove, key}

  defp decode_op(op), do: op

  # -- validate/3 -------------------------------------------------------------

  defp identity_findings(side, plan_hash, machine) do
    case Machine.identity(machine) do
      %Identity{content_hash: ^plan_hash} ->
        []

      %Identity{content_hash: machine_hash} ->
        [{:identity_mismatch, side, plan_hash, machine_hash}]

      nil ->
        [{:identity_mismatch, side, plan_hash, nil}]
    end
  end

  defp mapping_findings(field, mapping, from_machine, to_machine) do
    mapping
    |> Enum.sort()
    |> Enum.flat_map(fn {source, target} ->
      source_end = {from_machine, index(from_machine, source)}
      target_end = {to_machine, index(to_machine, target)}

      unknown(:unknown_source, field, source, elem(source_end, 1)) ++
        unknown(:unknown_target, field, target, elem(target_end, 1)) ++
        history_findings(field, source, target, source_end, target_end)
    end)
  end

  defp drop_findings(drop, from_machine) do
    Enum.flat_map(drop, &unknown(:unknown_source, :drop, &1, index(from_machine, &1)))
  end

  defp unknown(kind, field, id, nil), do: [{kind, field, id}]
  defp unknown(_kind, _field, _id, _index), do: []

  # The history rule needs both ends known; an unknown end is already a finding.
  defp history_findings(_field, _source, _target, {_from, nil}, _to), do: []
  defp history_findings(_field, _source, _target, _from, {_to, nil}), do: []

  defp history_findings(:states, source, target, {from, source_index}, {to, target_index}) do
    if Machine.history?(from, source_index) and not Machine.history?(to, target_index),
      do: [{:history_mismatch, :states, source, target}],
      else: []
  end

  defp history_findings(:history, source, target, {from, source_index}, {to, target_index}) do
    if Machine.history?(from, source_index) and Machine.history?(to, target_index),
      do: [],
      else: [{:history_mismatch, :history, source, target}]
  end

  defp duplicate_source_findings(plan) do
    (Map.keys(plan.states) ++ plan.drop ++ Map.keys(plan.history))
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> {:duplicate_source, id} end)
    |> Enum.sort()
  end

  defp invocation_findings(invocations, from_machine, to_machine) do
    per_invocation =
      Enum.flat_map(invocations, fn {from_id, from_ordinal, to_id, to_ordinal} ->
        ordinal_findings(:from, from_machine, from_id, from_ordinal) ++
          ordinal_findings(:to, to_machine, to_id, to_ordinal)
      end)

    per_invocation ++
      duplicate_invocations(:from, Enum.map(invocations, fn {s, o, _t, _p} -> {s, o} end)) ++
      duplicate_invocations(:to, Enum.map(invocations, fn {_s, _o, t, p} -> {t, p} end))
  end

  defp ordinal_findings(side, machine, state_id, ordinal) do
    case index(machine, state_id) do
      nil ->
        kind = if side == :from, do: :unknown_source, else: :unknown_target
        [{kind, :invocations, state_id}]

      state_index ->
        invoke_count = machine |> Machine.at(state_index) |> Map.fetch!(:invoke) |> length()

        if ordinal < invoke_count,
          do: [],
          else: [{:invocation_out_of_range, side, state_id, ordinal, invoke_count}]
    end
  end

  defp duplicate_invocations(side, keys) do
    keys
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> {:duplicate_invocation, side, key} end)
    |> Enum.sort()
  end

  defp index(machine, id) do
    case Machine.index(machine, id) do
      {:ok, index} -> index
      :error -> nil
    end
  end
end
