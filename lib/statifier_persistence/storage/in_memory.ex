defmodule StatifierPersistence.Storage.InMemory do
  @moduledoc """
  The reference `StatifierPersistence.Storage.Adapter`: an Agent holding
  three maps - charts keyed by content hash, positions keyed by session id,
  and executions keyed by execution id.

  The chart map is keyed by the content hash alone, as every adapter's is:
  byte-identical charts stored by two tenants are one entry, and tenant
  scoping is the host's own (`StatifierPersistence.Storage`'s moduledoc).

  It ships in `lib/`, not the test-only `support/` directory, for two
  reasons: the conformance template this package ships in `lib/` (this
  package's own `Testing` namespace) needs a reference implementation to
  check against from outside this repository's own `test/`, and a host
  prototyping the stepper wants an adapter with no database to stand up.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage.Adapter

  @typedoc """
  This adapter's state: the three record maps `init/1` starts the Agent
  with, plus the per-execution lock table `lock_execution/3` acquires through.
  """
  @type state :: %{
          charts: %{Adapter.content_hash() => Adapter.chart_record()},
          positions: %{Adapter.session_id() => Adapter.position_record()},
          executions: %{Adapter.execution_id() => Adapter.execution_record()},
          locks: %{Adapter.execution_id() => reference()}
        }

  # How long a contended lock_execution/3 sleeps between acquisition attempts.
  @lock_spin_sleep_ms 5

  # Every key of the drained query's answer at zero: what an unknown hash
  # answers, and what a hash with executions on it is folded onto, so a
  # missing arm is impossible rather than merely unlikely - and the fold's
  # `Map.update!/3` raises on a status with no key here.
  @zero_counts %{
    active: 0,
    needs_migration: 0,
    completed: 0,
    failed: 0,
    cancelled: 0,
    children: 0
  }

  # The arms whose execution pins a chart (ADR-0012 decision 1, as
  # ADR-0014 decision 4 reads it): a durable child's pin counts while its
  # parent is in one of them.
  @pinning_statuses [:active, :needs_migration]

  @doc """
  Starts the backing Agent and returns `opts` with `:pid` merged in - the
  handle every other callback expects as its first argument.
  """
  @impl Adapter
  @spec init(Adapter.opts()) :: {:ok, Adapter.opts()} | {:error, Adapter.error()}
  def init(opts) do
    case Agent.start_link(fn -> %{charts: %{}, positions: %{}, executions: %{}, locks: %{}} end) do
      {:ok, pid} -> {:ok, Keyword.put(opts, :pid, pid)}
      {:error, reason} -> {:error, {:adapter, reason}}
    end
  end

  @doc """
  Stores `chart_record` under its `content_hash`, idempotent on repeat
  writes of the same hash.

  A tombstoned hash is refused with `{:error, {:chart_retired, info}}`
  and is not revived (ADR-0012 decision 6). The read of the tombstone
  and the write are one `Agent.get_and_update/2`, which is this
  adapter's transaction.
  """
  @impl Adapter
  @spec save_chart(Adapter.opts(), Adapter.chart_record()) :: :ok | {:error, Adapter.error()}
  def save_chart(opts, %{content_hash: content_hash} = chart_record) do
    Agent.get_and_update(pid(opts), fn state ->
      case retired_info(get_in(state, [:charts, content_hash])) do
        nil -> {:ok, put_in(state, [:charts, content_hash], chart_record)}
        info -> {{:error, {:chart_retired, info}}, state}
      end
    end)
  end

  @doc """
  Fetches the chart stored under `content_hash`, or `:chart_not_found`.

  A tombstoned hash answers `{:error, {:chart_retired, info}}` instead
  (ADR-0012 decision 6): the entry is still there and its blobs are
  `nil`, and an entry with `nil` blobs is not a chart this adapter
  holds.
  """
  @impl Adapter
  @spec fetch_chart(Adapter.opts(), Adapter.content_hash()) ::
          {:ok, Adapter.chart_record()} | {:error, Adapter.error()}
  def fetch_chart(opts, content_hash) do
    chart_record = Agent.get(pid(opts), &get_in(&1, [:charts, content_hash]))

    case {chart_record, retired_info(chart_record)} do
      {nil, _none} -> {:error, :chart_not_found}
      {_tombstone, %{} = info} -> {:error, {:chart_retired, info}}
      {chart_record, nil} -> {:ok, chart_record}
    end
  end

  @doc """
  Declares the narrow tombstone read (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_retired_info?/1`).
  """
  @impl Adapter
  @spec supports_retired_info?(Adapter.opts()) :: boolean()
  def supports_retired_info?(_opts), do: true

  @doc """
  Reads the tombstone on `content_hash`, or `nil` for a hash that has
  none (the optional
  `c:StatifierPersistence.Storage.Adapter.fetch_retired_info/2`).

  The Agent answers with the tombstone alone rather than the stored
  entry, so the reply carries no chart bytes.
  """
  @impl Adapter
  @spec fetch_retired_info(Adapter.opts(), Adapter.content_hash()) ::
          {:ok, Adapter.retired_info() | nil}
  def fetch_retired_info(opts, content_hash) do
    {:ok, Agent.get(pid(opts), &retired_info(get_in(&1, [:charts, content_hash])))}
  end

  # The tombstone on one stored entry, or nil for an entry that carries
  # none. An entry that was never stored carries none either, and
  # `:chart_not_found` is the answer for that, given by the caller.
  @spec retired_info(Adapter.chart_record() | nil) :: Adapter.retired_info() | nil
  defp retired_info(%{retired_at: %DateTime{} = retired_at} = chart_record),
    do: %{retired_at: retired_at, retired_by: Map.get(chart_record, :retired_by)}

  defp retired_info(_no_tombstone), do: nil

  @doc """
  Stores `position_record` under its `session_id`, overwriting any position
  already stored for that session.
  """
  @impl Adapter
  @spec save_position(Adapter.opts(), Adapter.position_record()) ::
          :ok | {:error, Adapter.error()}
  def save_position(opts, %{session_id: session_id} = position_record) do
    agent(opts, fn state ->
      put_in(state, [:positions, session_id], position_record)
    end)
  end

  @doc """
  Fetches the position stored for `session_id`, or `:position_not_found`.
  """
  @impl Adapter
  @spec fetch_position(Adapter.opts(), Adapter.session_id()) ::
          {:ok, Adapter.position_record()} | {:error, Adapter.error()}
  def fetch_position(opts, session_id) do
    case Agent.get(pid(opts), &get_in(&1, [:positions, session_id])) do
      nil -> {:error, :position_not_found}
      position_record -> {:ok, position_record}
    end
  end

  @doc """
  Inserts `execution_record` under its `execution_id`, refusing a duplicate with
  `{:error, :execution_exists}`.

  The exists-check and the write run inside one `Agent.get_and_update/2`
  call, so they are a single atomic state transition: two concurrent
  inserts of the same `execution_id` cannot both return `:ok`.

  This adapter supports the optional `metadata` map (ADR-0006 decision 3):
  the map is stored with the record and returned by `fetch_execution/2` verbatim,
  whatever Elixir terms it holds - an Agent has no type system to refuse
  one.
  """
  @impl Adapter
  @spec insert_execution(Adapter.opts(), Adapter.execution_record()) ::
          :ok | {:error, Adapter.error()}
  def insert_execution(opts, %{execution_id: execution_id} = execution_record) do
    execution_record =
      execution_record
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:outcome_blob, nil)
      |> Map.put_new(:ended_at, nil)

    Agent.get_and_update(pid(opts), fn state ->
      if Map.has_key?(state.executions, execution_id) do
        {{:error, :execution_exists}, state}
      else
        {:ok, put_in(state, [:executions, execution_id], execution_record)}
      end
    end)
  end

  @doc """
  Fetches the execution stored under `execution_id`, or `:execution_not_found`.
  """
  @impl Adapter
  @spec fetch_execution(Adapter.opts(), Adapter.execution_id()) ::
          {:ok, Adapter.execution_record()} | {:error, Adapter.error()}
  def fetch_execution(opts, execution_id) do
    case Agent.get(pid(opts), &get_in(&1, [:executions, execution_id])) do
      nil -> {:error, :execution_not_found}
      execution_record -> {:ok, execution_record}
    end
  end

  @doc """
  Overwrites the execution stored under `execution_record`'s `execution_id` with the full
  record, or refuses with `:execution_not_found` when no execution exists for the id.

  `metadata` is the documented exception to the full overwrite: it is
  write-once (ADR-0006 decision 1 grants no way to change it after create),
  so the stored map is carried forward and the given record's `metadata`
  is ignored. `outcome_blob` is the second exception: a `nil` in the given
  record carries the stored value forward, and a binary sets it.
  `ended_at` is the third: a stored stamp is kept whatever the given
  record carries, and only a record with no stamp stored takes the given
  one.
  """
  @impl Adapter
  @spec update_execution(Adapter.opts(), Adapter.execution_record()) ::
          :ok | {:error, Adapter.error()}
  def update_execution(opts, %{execution_id: execution_id} = execution_record) do
    Agent.get_and_update(pid(opts), fn state ->
      case state.executions do
        %{^execution_id => stored} ->
          {:ok,
           put_in(state, [:executions, execution_id], carry_forward(execution_record, stored))}

        _absent ->
          {{:error, :execution_not_found}, state}
      end
    end)
  end

  @spec carry_forward(Adapter.execution_record(), Adapter.execution_record()) ::
          Adapter.execution_record()
  defp carry_forward(execution_record, stored) do
    outcome_blob = Map.get(execution_record, :outcome_blob) || Map.get(stored, :outcome_blob)
    ended_at = Map.get(stored, :ended_at) || Map.get(execution_record, :ended_at)

    execution_record
    |> Map.put(:metadata, Map.get(stored, :metadata, %{}))
    |> Map.put(:outcome_blob, outcome_blob)
    |> Map.put(:ended_at, ended_at)
  end

  @doc """
  Declares outcome support (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_execution_outcome?/1`): this
  adapter keeps the blob on the execution record like every other field.
  """
  @impl Adapter
  @spec supports_execution_outcome?(Adapter.opts()) :: boolean()
  def supports_execution_outcome?(_opts), do: true

  @doc """
  The status projection over a metadata match (the optional
  `c:StatifierPersistence.Storage.Adapter.list_execution_states_by_metadata/2`).

  The same containment `list_executions_by_metadata/2` applies, projected down
  to the three `t:StatifierPersistence.Storage.Adapter.execution_state/0`
  fields. There is no index to serve it from here - an Agent holds a map -
  so this is the reference implementation of the *contract*, not of the
  performance the contract exists for; the Ecto adapter is where the
  projection is a projection.
  """
  @impl Adapter
  @spec list_execution_states_by_metadata(Adapter.opts(), Adapter.metadata()) ::
          {:ok, [Adapter.execution_state()]} | {:error, Adapter.error()}
  def list_execution_states_by_metadata(opts, metadata) do
    with {:ok, executions} <- list_executions_by_metadata(opts, metadata) do
      {:ok, Enum.map(executions, &to_execution_state/1)}
    end
  end

  @spec to_execution_state(Adapter.execution_record()) :: Adapter.execution_state()
  defp to_execution_state(execution_record) do
    child_index =
      execution_record
      |> Map.get(:metadata, %{})
      |> Map.get(Linkage.reserved_key(), %{})
      |> Map.get("child_index")

    %{
      execution_id: execution_record.execution_id,
      status: execution_record.status,
      child_index: child_index
    }
  end

  @doc """
  Declares metadata support (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1`): this
  adapter stores the map with the execution record and returns it verbatim
  (ADR-0006 decision 3).
  """
  @impl Adapter
  @spec supports_metadata?(Adapter.opts()) :: boolean()
  def supports_metadata?(_opts), do: true

  @doc """
  Lists the executions whose stored `metadata` contains **every** key/value pair
  in `metadata`, recursively for a nested map (the optional
  `c:StatifierPersistence.Storage.Adapter.list_executions_by_metadata/2`,
  ADR-0008 decision 5) - the same subset semantics
  `StatifierPersistence.Storage.Ecto`'s `jsonb @>` gives, and the same
  `ArgumentError` on an empty or non-string-keyed map.
  """
  @impl Adapter
  @spec list_executions_by_metadata(Adapter.opts(), Adapter.metadata()) ::
          {:ok, [Adapter.execution_record()]} | {:error, Adapter.error()}
  def list_executions_by_metadata(opts, metadata) do
    validate_match!(metadata)

    executions =
      pid(opts)
      |> Agent.get(& &1.executions)
      |> Map.values()
      |> Enum.filter(&contains?(Map.get(&1, :metadata, %{}), metadata))

    {:ok, executions}
  end

  # Recursive containment, matching the Ecto adapter's `jsonb @>`: every pair
  # in `match` is present in `stored`, and a map value contains rather than
  # equals.
  @spec contains?(map(), map()) :: boolean()
  defp contains?(stored, match) when is_map(stored) and is_map(match) do
    Enum.all?(match, fn {key, value} ->
      case Map.fetch(stored, key) do
        {:ok, stored_value} when is_map(value) and is_map(stored_value) ->
          contains?(stored_value, value)

        {:ok, stored_value} ->
          stored_value == value

        :error ->
          false
      end
    end)
  end

  @spec validate_match!(term()) :: :ok
  defp validate_match!(metadata)
       when is_map(metadata) and map_size(metadata) > 0 do
    if Enum.all?(Map.keys(metadata), &is_binary/1) do
      :ok
    else
      raise ArgumentError,
            "list_executions_by_metadata/2 takes a map with string keys, got keys: " <>
              inspect(Map.keys(metadata))
    end
  end

  defp validate_match!(other) do
    raise ArgumentError,
          "list_executions_by_metadata/2 takes a non-empty map with string keys, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Declares the drained query (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_content_hash_query?/1`):
  this adapter holds every execution record in one map and can count them.
  """
  @impl Adapter
  @spec supports_content_hash_query?(Adapter.opts()) :: boolean()
  def supports_content_hash_query?(_opts), do: true

  @doc """
  Counts the executions on `content_hash` per stored arm (the optional
  `c:StatifierPersistence.Storage.Adapter.count_executions_by_content_hash/2`,
  ADR-0012 decision 3).

  Every key is present for every hash, so an unknown one answers zeros.
  A fold over the execution map is what this adapter has - an Agent holds
  no index - so this is the reference implementation of the *contract*,
  not of the aggregate the contract exists for; the Ecto adapter is where
  the count is a grouped count.

  `children` counts the durable-child linkage pins naming `content_hash`
  whose parent execution is `:active` or `:needs_migration` (ADR-0012
  decision 1, as ADR-0014 decision 4 reads it): a second
  pass over the same map, reading each execution's reserved metadata key
  through `StatifierPersistence.Execution.Linkage.from_metadata/1` and
  looking its parent up by execution id.
  """
  @impl Adapter
  @spec count_executions_by_content_hash(Adapter.opts(), Adapter.content_hash()) ::
          {:ok, Adapter.execution_counts()} | {:error, Adapter.error()}
  def count_executions_by_content_hash(opts, content_hash) do
    {:ok, execution_counts(Agent.get(pid(opts), & &1.executions), content_hash)}
  end

  @spec execution_counts(
          %{Adapter.execution_id() => Adapter.execution_record()},
          Adapter.content_hash()
        ) :: Adapter.execution_counts()
  defp execution_counts(executions, content_hash) do
    counts =
      executions
      |> Map.values()
      |> Enum.filter(&(&1.content_hash == content_hash))
      |> Enum.reduce(@zero_counts, fn execution, counts ->
        Map.update!(counts, execution.status, &(&1 + 1))
      end)

    %{counts | children: children_pin_count(executions, content_hash)}
  end

  # ADR-0012 decision 1's child clause: a linkage pin naming this hash
  # counts for as long as the execution its `parent_execution_id` names
  # is `:active` or `:needs_migration`, whatever arm the child itself is
  # in. The pin is read
  # off the child's metadata rather than taken from the child's
  # `content_hash` field, because the pin is the value the decision
  # names and the two are written by separate calls.
  @spec children_pin_count(
          %{Adapter.execution_id() => Adapter.execution_record()},
          Adapter.content_hash()
        ) :: non_neg_integer()
  defp children_pin_count(executions, content_hash) do
    executions
    |> Map.values()
    |> Enum.count(&pinned_child?(&1, executions, content_hash))
  end

  @spec pinned_child?(
          Adapter.execution_record(),
          %{Adapter.execution_id() => Adapter.execution_record()},
          Adapter.content_hash()
        ) :: boolean()
  defp pinned_child?(execution, executions, content_hash) do
    metadata = Map.get(execution, :metadata) || %{}

    case Linkage.from_metadata(metadata) do
      {:ok, %Linkage{content_hash: ^content_hash, parent_execution_id: parent_execution_id}} ->
        match?(
          %{status: status} when status in @pinning_statuses,
          Map.get(executions, parent_execution_id)
        )

      _no_pin_on_this_hash ->
        false
    end
  end

  @doc """
  Lists the ids of the `:active` executions on `content_hash` (the
  optional
  `c:StatifierPersistence.Storage.Adapter.list_active_execution_ids_by_content_hash/2`,
  ADR-0012 decision 4): what a pin source is handed as its context.

  A filter over the same execution map the counts fold over, in the
  order the map yields, which is no order a caller may rely on: the
  contract is a list of ids, not a sequence.
  """
  @impl Adapter
  @spec list_active_execution_ids_by_content_hash(Adapter.opts(), Adapter.content_hash()) ::
          {:ok, [Adapter.execution_id()]} | {:error, Adapter.error()}
  def list_active_execution_ids_by_content_hash(opts, content_hash) do
    ids =
      pid(opts)
      |> Agent.get(& &1.executions)
      |> Map.values()
      |> Enum.filter(&match?(%{status: :active, content_hash: ^content_hash}, &1))
      |> Enum.map(& &1.execution_id)

    {:ok, ids}
  end

  @doc """
  Declares chart retirement (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_chart_retirement?/1`,
  ADR-0012 decision 6): an Agent's map has no `NOT NULL` to drop, so
  the backend limit V07 records on a database adapter has no
  counterpart here.
  """
  @impl Adapter
  @spec supports_chart_retirement?(Adapter.opts()) :: boolean()
  def supports_chart_retirement?(_opts), do: true

  @doc """
  Retires the chart on `content_hash` (the optional
  `c:StatifierPersistence.Storage.Adapter.retire_chart/3`, ADR-0012
  decisions 5 and 6).

  The counts and the tombstone are one `Agent.get_and_update/2`, which
  is this adapter's whole answer to the callback's atomicity contract:
  the Agent serves one message at a time, so nothing can be created on
  the hash between the counting and the write.

  A refused retirement returns the state unchanged, and the refusal
  carries every count - the five execution arms, the durable-child
  pins, the position rows, and each source's own counts - while only
  ADR-0012 decision 1's blocking set causes one.

  The tombstone keeps the entry and its content hash and nulls both
  blobs, which is what makes the retired arm of `fetch_chart/2`
  answerable at all.
  """
  @impl Adapter
  @spec retire_chart(Adapter.opts(), Adapter.content_hash(), Adapter.retirement()) ::
          {:ok, Adapter.retired_info()} | {:error, Adapter.error()}
  def retire_chart(opts, content_hash, retirement) do
    Agent.get_and_update(pid(opts), fn state ->
      case get_in(state, [:charts, content_hash]) do
        nil -> {{:error, :chart_not_found}, state}
        chart_record -> retire_stored(state, content_hash, chart_record, retirement)
      end
    end)
  end

  @spec retire_stored(
          state(),
          Adapter.content_hash(),
          Adapter.chart_record(),
          Adapter.retirement()
        ) :: {{:ok, Adapter.retired_info()} | {:error, Adapter.error()}, state()}
  defp retire_stored(state, content_hash, chart_record, retirement) do
    counts =
      Adapter.pin_counts(
        execution_counts(state.executions, content_hash),
        position_count(state.positions, content_hash),
        retirement.sources
      )

    cond do
      info = retired_info(chart_record) -> {{:error, {:chart_retired, info}}, state}
      Adapter.pinned?(counts) -> {{:error, {:pinned, counts}}, state}
      true -> tombstone(state, content_hash, chart_record, retirement)
    end
  end

  @spec tombstone(
          state(),
          Adapter.content_hash(),
          Adapter.chart_record(),
          Adapter.retirement()
        ) :: {{:ok, Adapter.retired_info()}, state()}
  defp tombstone(state, content_hash, chart_record, retirement) do
    tombstoned = %{
      chart_record
      | identity_blob: nil,
        chart_blob: nil
    }

    tombstoned =
      tombstoned
      |> Map.put(:retired_at, retirement.retired_at)
      |> Map.put(:retired_by, retirement.retired_by)

    {{:ok, %{retired_at: retirement.retired_at, retired_by: retirement.retired_by}},
     put_in(state, [:charts, content_hash], tombstoned)}
  end

  # ADR-0012 decision 1's fourth pin kind, which decision 3's map leaves
  # out: a position row is a saved session waiting to be resumed
  # through `load_position/3`, and resuming it needs the bytes this
  # retirement would null. Positions are keyed by session, so a hash
  # with no execution at all can still hold them.
  @spec position_count(
          %{Adapter.session_id() => Adapter.position_record()},
          Adapter.content_hash()
        ) :: non_neg_integer()
  defp position_count(positions, content_hash) do
    positions
    |> Map.values()
    |> Enum.count(&(&1.content_hash == content_hash))
  end

  @doc """
  Declares execution pruning (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_execution_pruning?/1`,
  ADR-0016).
  """
  @impl Adapter
  @spec supports_execution_pruning?(Adapter.opts()) :: boolean()
  def supports_execution_pruning?(_opts), do: true

  @doc """
  Prunes one batch of finished executions (the optional
  `c:StatifierPersistence.Storage.Adapter.prune_executions/4`,
  ADR-0016): one `Agent.get_and_update/2`, this adapter's transaction.

  This adapter keeps no input log (ADR-0010 decision 1), so a batch
  holds only the executions that still carry a position blob, and it
  answers `inputs: 0`.

  Its records have no host columns to hold a scope, so it answers
  `{:error, :unscoped_adapter}` for any scope that is not `[]`, and
  clears nothing.
  """
  @impl Adapter
  @spec prune_executions(Adapter.opts(), DateTime.t(), pos_integer(), Adapter.prune_scope()) ::
          {:ok, Adapter.prune_counts()} | {:error, Adapter.error()}
  def prune_executions(opts, cutoff, limit, scope)

  def prune_executions(opts, %DateTime{} = cutoff, limit, [])
      when is_integer(limit) and limit > 0 do
    Agent.get_and_update(pid(opts), fn state ->
      due =
        state.executions
        |> Map.values()
        |> Enum.filter(&prunable?(&1, cutoff))
        |> Enum.sort_by(&{DateTime.to_unix(&1.ended_at, :microsecond), &1.execution_id})
        |> Enum.take(limit)

      executions =
        Enum.reduce(due, state.executions, fn record, executions ->
          Map.put(executions, record.execution_id, %{record | position_blob: nil})
        end)

      counts = %{executions: length(due), position_blobs: length(due), inputs: 0}

      {{:ok, counts}, %{state | executions: executions}}
    end)
  end

  def prune_executions(_opts, %DateTime{}, limit, [_ | _])
      when is_integer(limit) and limit > 0,
      do: {:error, :unscoped_adapter}

  @spec prunable?(Adapter.execution_record(), DateTime.t()) :: boolean()
  defp prunable?(%{status: status, ended_at: %DateTime{} = ended_at} = record, cutoff)
       when status in [:completed, :failed, :cancelled] do
    DateTime.before?(ended_at, cutoff) and not is_nil(record.position_blob)
  end

  defp prunable?(_record, _cutoff), do: false

  @doc """
  Declares the tree migration unit (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_tree_migration?/1`,
  ADR-0015 decision 3).
  """
  @impl Adapter
  @spec supports_tree_migration?(Adapter.opts()) :: boolean()
  def supports_tree_migration?(_opts), do: true

  @doc """
  Writes a tree migration's re-pins and parks as one unit (the optional
  `c:StatifierPersistence.Storage.Adapter.write_tree_migration/2`,
  ADR-0015 decision 3).

  Every write is applied to one copy of the state inside one
  `Agent.get_and_update/2`, which is this adapter's transaction: the copy
  replaces the state only when every write applied, and a write naming an
  execution that is not stored answers `{:error, :execution_not_found}`
  with the state unchanged.
  """
  @impl Adapter
  @spec write_tree_migration(Adapter.opts(), [Adapter.tree_write()]) ::
          :ok | {:error, Adapter.error()}
  def write_tree_migration(opts, writes) when is_list(writes) do
    Agent.get_and_update(pid(opts), fn state ->
      case Enum.reduce_while(writes, {:ok, state.executions}, &tree_write/2) do
        {:ok, executions} -> {:ok, %{state | executions: executions}}
        {:error, _reason} = error -> {error, state}
      end
    end)
  end

  @spec tree_write(Adapter.tree_write(), {:ok, map()}) ::
          {:cont, {:ok, map()}} | {:halt, {:error, Adapter.error()}}
  defp tree_write(write, {:ok, executions}) do
    execution_id = tree_write_id(write)

    case executions do
      %{^execution_id => stored} ->
        {:cont, {:ok, Map.put(executions, execution_id, tree_written(write, stored))}}

      _absent ->
        {:halt, {:error, :execution_not_found}}
    end
  end

  defp tree_write_id({:repin, %{execution_id: execution_id}, _linkage_hash}), do: execution_id
  defp tree_write_id({:park, execution_id}), do: execution_id

  # A re-pin is `update_execution/2`'s carry-forward with the one sanctioned
  # rewrite of the linkage pin (ADR-0008's 2026-09-23 Amendment); a park is
  # `Storage.update_execution_status/4`'s status write.
  defp tree_written({:repin, record, linkage_hash}, stored) do
    record
    |> carry_forward(stored)
    |> Map.update!(:metadata, &repin_linkage(&1, linkage_hash))
  end

  defp tree_written({:park, _execution_id}, stored),
    do: %{stored | status: :needs_migration, failure: nil}

  defp repin_linkage(metadata, nil), do: metadata

  defp repin_linkage(metadata, linkage_hash) do
    case Map.fetch(metadata, Linkage.reserved_key()) do
      {:ok, %{} = reserved} ->
        Map.put(metadata, Linkage.reserved_key(), Map.put(reserved, "content_hash", linkage_hash))

      _no_linkage ->
        metadata
    end
  end

  @doc """
  Runs `fun` under this adapter's per-execution mutual exclusion for `execution_id`
  (the optional `c:StatifierPersistence.Storage.Adapter.lock_execution/3`).

  Acquisition is an insert-if-absent on the Agent's lock table, one atomic
  `Agent.get_and_update/2` transition; contention spins with a small
  bounded sleep (#{@lock_spin_sleep_ms}ms) between attempts. The lock is
  released in an `after` block, so any exit from `fun` - a raise included -
  releases it; the raise itself propagates to the caller.

  Simple and honest for a reference adapter. A production adapter should
  prefer its backend's native lock - the Ecto adapter implements this as
  a transaction-scoped advisory-plus-row lock (ADR-0004 decision 5 as
  amended 2026-08-22).
  """
  @impl Adapter
  @spec lock_execution(Adapter.opts(), Adapter.execution_id(), (-> result)) ::
          {:ok, result} | {:error, Adapter.error()}
        when result: term()
  def lock_execution(opts, execution_id, fun) do
    token = acquire_lock(pid(opts), execution_id)

    try do
      {:ok, fun.()}
    after
      release_lock(pid(opts), execution_id, token)
    end
  end

  @spec acquire_lock(pid(), Adapter.execution_id()) :: reference()
  defp acquire_lock(pid, execution_id) do
    token = make_ref()

    acquired? =
      Agent.get_and_update(pid, fn state ->
        if Map.has_key?(state.locks, execution_id) do
          {false, state}
        else
          {true, put_in(state, [:locks, execution_id], token)}
        end
      end)

    if acquired? do
      token
    else
      Process.sleep(@lock_spin_sleep_ms)
      acquire_lock(pid, execution_id)
    end
  end

  @spec release_lock(pid(), Adapter.execution_id(), reference()) :: :ok
  defp release_lock(pid, execution_id, token) do
    Agent.update(pid, fn state ->
      case state.locks do
        # Only the holder's own token releases: a stray release can never
        # drop a lock some later acquirer holds.
        %{^execution_id => ^token} -> %{state | locks: Map.delete(state.locks, execution_id)}
        _other -> state
      end
    end)
  end

  @spec pid(Adapter.opts()) :: pid()
  defp pid(opts), do: Keyword.fetch!(opts, :pid)

  @spec agent(Adapter.opts(), (state() -> state())) :: :ok
  defp agent(opts, update) do
    Agent.update(pid(opts), update)
  end
end
