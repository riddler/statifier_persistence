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
  """
  @impl Adapter
  @spec save_chart(Adapter.opts(), Adapter.chart_record()) :: :ok | {:error, Adapter.error()}
  def save_chart(opts, %{content_hash: content_hash} = chart_record) do
    agent(opts, fn state ->
      put_in(state, [:charts, content_hash], chart_record)
    end)
  end

  @doc """
  Fetches the chart stored under `content_hash`, or `:chart_not_found`.
  """
  @impl Adapter
  @spec fetch_chart(Adapter.opts(), Adapter.content_hash()) ::
          {:ok, Adapter.chart_record()} | {:error, Adapter.error()}
  def fetch_chart(opts, content_hash) do
    case Agent.get(pid(opts), &get_in(&1, [:charts, content_hash])) do
      nil -> {:error, :chart_not_found}
      chart_record -> {:ok, chart_record}
    end
  end

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

    execution_record
    |> Map.put(:metadata, Map.get(stored, :metadata, %{}))
    |> Map.put(:outcome_blob, outcome_blob)
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
  Executions `fun` under this adapter's per-execution mutual exclusion for `execution_id`
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
