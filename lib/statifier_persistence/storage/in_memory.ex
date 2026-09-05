defmodule StatifierPersistence.Storage.InMemory do
  @moduledoc """
  The reference `StatifierPersistence.Storage.Adapter`: an Agent holding
  three maps - charts keyed by content hash, positions keyed by session id,
  and runs keyed by run id.

  It ships in `lib/`, not the test-only `support/` directory, for two
  reasons: the conformance template this package ships in `lib/` (this
  package's own `Testing` namespace) needs a reference implementation to
  check against from outside this repository's own `test/`, and a host
  prototyping the stepper wants an adapter with no database to stand up.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.Adapter

  @typedoc """
  This adapter's state: the three record maps `init/1` starts the Agent
  with, plus the per-run lock table `lock_run/3` acquires through.
  """
  @type state :: %{
          charts: %{Adapter.content_hash() => Adapter.chart_record()},
          positions: %{Adapter.session_id() => Adapter.position_record()},
          runs: %{Adapter.run_id() => Adapter.run_record()},
          locks: %{Adapter.run_id() => reference()}
        }

  # How long a contended lock_run/3 sleeps between acquisition attempts.
  @lock_spin_sleep_ms 5

  @doc """
  Starts the backing Agent and returns `opts` with `:pid` merged in - the
  handle every other callback expects as its first argument.
  """
  @impl Adapter
  @spec init(Adapter.opts()) :: {:ok, Adapter.opts()} | {:error, Adapter.error()}
  def init(opts) do
    case Agent.start_link(fn -> %{charts: %{}, positions: %{}, runs: %{}, locks: %{}} end) do
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
  Inserts `run_record` under its `run_id`, refusing a duplicate with
  `{:error, :run_exists}`.

  The exists-check and the write run inside one `Agent.get_and_update/2`
  call, so they are a single atomic state transition: two concurrent
  inserts of the same `run_id` cannot both return `:ok`.

  This adapter supports the optional `metadata` map (ADR-0006 decision 3):
  the map is stored with the record and returned by `fetch_run/2` verbatim,
  whatever Elixir terms it holds - an Agent has no type system to refuse
  one.
  """
  @impl Adapter
  @spec insert_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
  def insert_run(opts, %{run_id: run_id} = run_record) do
    run_record =
      run_record
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:outcome_blob, nil)

    Agent.get_and_update(pid(opts), fn state ->
      if Map.has_key?(state.runs, run_id) do
        {{:error, :run_exists}, state}
      else
        {:ok, put_in(state, [:runs, run_id], run_record)}
      end
    end)
  end

  @doc """
  Fetches the run stored under `run_id`, or `:run_not_found`.
  """
  @impl Adapter
  @spec fetch_run(Adapter.opts(), Adapter.run_id()) ::
          {:ok, Adapter.run_record()} | {:error, Adapter.error()}
  def fetch_run(opts, run_id) do
    case Agent.get(pid(opts), &get_in(&1, [:runs, run_id])) do
      nil -> {:error, :run_not_found}
      run_record -> {:ok, run_record}
    end
  end

  @doc """
  Overwrites the run stored under `run_record`'s `run_id` with the full
  record, or refuses with `:run_not_found` when no run exists for the id.

  `metadata` is the documented exception to the full overwrite: it is
  write-once (ADR-0006 decision 1 grants no way to change it after create),
  so the stored map is carried forward and the given record's `metadata`
  is ignored. `outcome_blob` is the second exception: a `nil` in the given
  record carries the stored value forward, and a binary sets it.
  """
  @impl Adapter
  @spec update_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
  def update_run(opts, %{run_id: run_id} = run_record) do
    Agent.get_and_update(pid(opts), fn state ->
      case state.runs do
        %{^run_id => stored} ->
          {:ok, put_in(state, [:runs, run_id], carry_forward(run_record, stored))}

        _absent ->
          {{:error, :run_not_found}, state}
      end
    end)
  end

  @spec carry_forward(Adapter.run_record(), Adapter.run_record()) :: Adapter.run_record()
  defp carry_forward(run_record, stored) do
    outcome_blob = Map.get(run_record, :outcome_blob) || Map.get(stored, :outcome_blob)

    run_record
    |> Map.put(:metadata, Map.get(stored, :metadata, %{}))
    |> Map.put(:outcome_blob, outcome_blob)
  end

  @doc """
  Declares outcome support (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_run_outcome?/1`): this
  adapter keeps the blob on the run record like every other field.
  """
  @impl Adapter
  @spec supports_run_outcome?(Adapter.opts()) :: boolean()
  def supports_run_outcome?(_opts), do: true

  @doc """
  The status projection over a metadata match (the optional
  `c:StatifierPersistence.Storage.Adapter.list_run_states_by_metadata/2`).

  The same containment `list_runs_by_metadata/2` applies, projected down
  to the three `t:StatifierPersistence.Storage.Adapter.run_state/0`
  fields. There is no index to serve it from here - an Agent holds a map -
  so this is the reference implementation of the *contract*, not of the
  performance the contract exists for; the Ecto adapter is where the
  projection is a projection.
  """
  @impl Adapter
  @spec list_run_states_by_metadata(Adapter.opts(), Adapter.metadata()) ::
          {:ok, [Adapter.run_state()]} | {:error, Adapter.error()}
  def list_run_states_by_metadata(opts, metadata) do
    with {:ok, runs} <- list_runs_by_metadata(opts, metadata) do
      {:ok, Enum.map(runs, &to_run_state/1)}
    end
  end

  @spec to_run_state(Adapter.run_record()) :: Adapter.run_state()
  defp to_run_state(run_record) do
    child_index =
      run_record
      |> Map.get(:metadata, %{})
      |> Map.get(Linkage.reserved_key(), %{})
      |> Map.get("child_index")

    %{run_id: run_record.run_id, status: run_record.status, child_index: child_index}
  end

  @doc """
  Declares metadata support (the optional
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1`): this
  adapter stores the map with the run record and returns it verbatim
  (ADR-0006 decision 3).
  """
  @impl Adapter
  @spec supports_metadata?(Adapter.opts()) :: boolean()
  def supports_metadata?(_opts), do: true

  @doc """
  Lists the runs whose stored `metadata` contains **every** key/value pair
  in `metadata`, recursively for a nested map (the optional
  `c:StatifierPersistence.Storage.Adapter.list_runs_by_metadata/2`,
  ADR-0008 decision 5) - the same subset semantics
  `StatifierPersistence.Storage.Ecto`'s `jsonb @>` gives, and the same
  `ArgumentError` on an empty or non-string-keyed map.
  """
  @impl Adapter
  @spec list_runs_by_metadata(Adapter.opts(), Adapter.metadata()) ::
          {:ok, [Adapter.run_record()]} | {:error, Adapter.error()}
  def list_runs_by_metadata(opts, metadata) do
    validate_match!(metadata)

    runs =
      pid(opts)
      |> Agent.get(& &1.runs)
      |> Map.values()
      |> Enum.filter(&contains?(Map.get(&1, :metadata, %{}), metadata))

    {:ok, runs}
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
            "list_runs_by_metadata/2 takes a map with string keys, got keys: " <>
              inspect(Map.keys(metadata))
    end
  end

  defp validate_match!(other) do
    raise ArgumentError,
          "list_runs_by_metadata/2 takes a non-empty map with string keys, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Runs `fun` under this adapter's per-run mutual exclusion for `run_id`
  (the optional `c:StatifierPersistence.Storage.Adapter.lock_run/3`).

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
  @spec lock_run(Adapter.opts(), Adapter.run_id(), (-> result)) ::
          {:ok, result} | {:error, Adapter.error()}
        when result: term()
  def lock_run(opts, run_id, fun) do
    token = acquire_lock(pid(opts), run_id)

    try do
      {:ok, fun.()}
    after
      release_lock(pid(opts), run_id, token)
    end
  end

  @spec acquire_lock(pid(), Adapter.run_id()) :: reference()
  defp acquire_lock(pid, run_id) do
    token = make_ref()

    acquired? =
      Agent.get_and_update(pid, fn state ->
        if Map.has_key?(state.locks, run_id) do
          {false, state}
        else
          {true, put_in(state, [:locks, run_id], token)}
        end
      end)

    if acquired? do
      token
    else
      Process.sleep(@lock_spin_sleep_ms)
      acquire_lock(pid, run_id)
    end
  end

  @spec release_lock(pid(), Adapter.run_id(), reference()) :: :ok
  defp release_lock(pid, run_id, token) do
    Agent.update(pid, fn state ->
      case state.locks do
        # Only the holder's own token releases: a stray release can never
        # drop a lock some later acquirer holds.
        %{^run_id => ^token} -> %{state | locks: Map.delete(state.locks, run_id)}
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
