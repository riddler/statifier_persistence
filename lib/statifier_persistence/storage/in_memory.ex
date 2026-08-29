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
    run_record = Map.put_new(run_record, :metadata, %{})

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
  is ignored.
  """
  @impl Adapter
  @spec update_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
  def update_run(opts, %{run_id: run_id} = run_record) do
    Agent.get_and_update(pid(opts), fn state ->
      case state.runs do
        %{^run_id => stored} ->
          kept = Map.put(run_record, :metadata, Map.get(stored, :metadata, %{}))
          {:ok, put_in(state, [:runs, run_id], kept)}

        _absent ->
          {{:error, :run_not_found}, state}
      end
    end)
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
