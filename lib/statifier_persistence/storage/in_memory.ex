defmodule StatifierPersistence.Storage.InMemory do
  @moduledoc """
  The reference `StatifierPersistence.Storage.Adapter`: an Agent holding two
  maps, charts keyed by content hash and positions keyed by session id.

  It ships in `lib/`, not the test-only `support/` directory, for two
  reasons: the conformance template this package ships in `lib/` (this
  package's own `Testing` namespace) needs a reference implementation to
  check against from outside this repository's own `test/`, and a host
  prototyping the stepper wants an adapter with no database to stand up.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage.Adapter

  @typedoc "This adapter's state: the two maps `init/1` starts the Agent with."
  @type state :: %{
          charts: %{Adapter.content_hash() => Adapter.chart_record()},
          positions: %{Adapter.session_id() => Adapter.position_record()}
        }

  @doc """
  Starts the backing Agent and returns `opts` with `:pid` merged in - the
  handle every other callback expects as its first argument.
  """
  @impl Adapter
  @spec init(Adapter.opts()) :: {:ok, Adapter.opts()} | {:error, Adapter.error()}
  def init(opts) do
    case Agent.start_link(fn -> %{charts: %{}, positions: %{}} end) do
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

  @spec pid(Adapter.opts()) :: pid()
  defp pid(opts), do: Keyword.fetch!(opts, :pid)

  @spec agent(Adapter.opts(), (state() -> state())) :: :ok
  defp agent(opts, update) do
    Agent.update(pid(opts), update)
  end
end
