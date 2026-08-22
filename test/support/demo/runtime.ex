defmodule StatifierPersistence.Demo.Runtime do
  @moduledoc """
  The demo host's volatile layer (Phase 1 of
  `docs/plans/260822-sp-4an.4-restart-demo-host.md`): a `Supervisor` over
  two `Agent` children plus a monotonic mock clock. Stopping it is the
  simulated node death - everything it owns, including the invoke worker
  processes it spawned, dies with it, and nothing here is durable.

  - `Timers` - the mock clock (`now_ms`) and the set of armed timer keys,
    each mapped to the `due_at_ms` it fires at. `StatifierPersistence.Demo.Ledger`
    holds the timer's payload (event/data/send_id); this agent holds only
    scheduling state, mirroring the split the plan draws between "what
    survives" (the ledger) and "what does not" (this).
  - `Workers` - one real spawned `Agent` per live invocation, keyed by
    `invoke_id`. Each worker is a genuine process so "the pid died with the
    node" and "a different pid serves it now" (post-restart) are both
    directly observable rather than asserted by convention.

  No wall-clock timer anywhere: the mock clock only advances when a test
  calls `due/2`, which is what keeps the demo fast and deterministic.
  """

  alias StatifierPersistence.Demo.Runtime.{Timers, Workers}

  @type ordinal :: pos_integer()

  @type t :: %{sup: pid(), timers: pid(), workers: pid()}

  @doc "Starts a fresh runtime: a supervisor over one `Timers` agent and one `Workers` agent."
  @spec start_link(term()) :: {:ok, t()} | {:error, term()}
  def start_link(_opts \\ []) do
    with {:ok, sup} <- Supervisor.start_link([Timers, Workers], strategy: :one_for_one) do
      children = Supervisor.which_children(sup)

      {:ok,
       %{sup: sup, timers: child_pid(children, Timers), workers: child_pid(children, Workers)}}
    end
  end

  @spec child_pid([tuple()], module()) :: pid()
  defp child_pid(children, module) do
    Enum.find_value(children, fn {id, pid, _type, _mods} -> id == module and pid end)
  end

  @doc """
  Simulates the node dying: every worker process this runtime spawned is
  stopped first (they are not supervisor children - only `Timers` and
  `Workers` are - so stopping the supervisor alone would leave them
  running), then the supervisor itself is stopped.
  """
  @spec stop(t()) :: :ok
  def stop(%{sup: sup, workers: workers}) do
    workers
    |> Workers.pids()
    |> Enum.each(fn pid -> if Process.alive?(pid), do: Agent.stop(pid) end)

    Supervisor.stop(sup)
  end

  @doc "Arms `ordinal` to fire at `due_at_ms` (absolute mock-clock milliseconds)."
  @spec arm(t(), ordinal(), non_neg_integer()) :: :ok
  def arm(%{timers: timers}, ordinal, due_at_ms), do: Timers.arm(timers, ordinal, due_at_ms)

  @doc "Disarms `ordinal`, whether or not it was armed."
  @spec disarm(t(), ordinal()) :: :ok
  def disarm(%{timers: timers}, ordinal), do: Timers.disarm(timers, ordinal)

  @doc "The armed ordinals right now, with no clock advance."
  @spec armed(t()) :: MapSet.t(ordinal())
  def armed(%{timers: timers}), do: Timers.armed(timers)

  @doc """
  Advances the mock clock by `delta_ms` and returns every armed ordinal
  whose `due_at_ms` is now at or before the new clock time, disarming each
  one it returns (a fired timer is no longer armed).
  """
  @spec due(t(), non_neg_integer()) :: [ordinal()]
  def due(%{timers: timers}, delta_ms), do: Timers.advance(timers, delta_ms)

  @doc "The mock clock's current time, in milliseconds."
  @spec now_ms(t()) :: non_neg_integer()
  def now_ms(%{timers: timers}), do: Timers.now_ms(timers)

  @doc "Spawns a fresh worker process for `invoke_id`, replacing any prior one under the same id."
  @spec start_worker(t(), String.t(), term()) :: pid()
  def start_worker(%{workers: workers}, invoke_id, payload),
    do: Workers.start(workers, invoke_id, payload)

  @doc "The live worker pid for `invoke_id`, or `nil` if none is running."
  @spec worker(t(), String.t()) :: pid() | nil
  def worker(%{workers: workers}, invoke_id), do: Workers.get(workers, invoke_id)

  @doc "Stops the worker for `invoke_id`, if one is running."
  @spec stop_worker(t(), String.t()) :: :ok
  def stop_worker(%{workers: workers}, invoke_id), do: Workers.stop(workers, invoke_id)

  defmodule Timers do
    @moduledoc false
    use Agent

    @spec start_link(term()) :: Agent.on_start()
    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{now_ms: 0, armed: %{}} end)
    end

    @spec arm(pid(), pos_integer(), non_neg_integer()) :: :ok
    def arm(timers, ordinal, due_at_ms) do
      Agent.update(timers, fn state -> put_in(state.armed[ordinal], due_at_ms) end)
    end

    @spec disarm(pid(), pos_integer()) :: :ok
    def disarm(timers, ordinal) do
      Agent.update(timers, fn state -> update_in(state.armed, &Map.delete(&1, ordinal)) end)
    end

    @spec armed(pid()) :: MapSet.t(pos_integer())
    def armed(timers) do
      Agent.get(timers, fn state -> state.armed |> Map.keys() |> MapSet.new() end)
    end

    @spec advance(pid(), non_neg_integer()) :: [pos_integer()]
    def advance(timers, delta_ms) do
      Agent.get_and_update(timers, fn state ->
        now_ms = state.now_ms + delta_ms

        {due, armed} =
          Enum.split_with(state.armed, fn {_ordinal, due_at_ms} -> due_at_ms <= now_ms end)

        ordinals = due |> Enum.map(fn {ordinal, _due_at_ms} -> ordinal end) |> Enum.sort()
        {ordinals, %{now_ms: now_ms, armed: Map.new(armed)}}
      end)
    end

    @spec now_ms(pid()) :: non_neg_integer()
    def now_ms(timers), do: Agent.get(timers, & &1.now_ms)
  end

  defmodule Workers do
    @moduledoc false
    use Agent

    @spec start_link(term()) :: Agent.on_start()
    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{} end)
    end

    @spec start(pid(), String.t(), term()) :: pid()
    def start(workers, invoke_id, payload) do
      {:ok, worker_pid} = Agent.start_link(fn -> payload end)
      Agent.update(workers, &Map.put(&1, invoke_id, worker_pid))
      worker_pid
    end

    @spec get(pid(), String.t()) :: pid() | nil
    def get(workers, invoke_id), do: Agent.get(workers, &Map.get(&1, invoke_id))

    @spec stop(pid(), String.t()) :: :ok
    def stop(workers, invoke_id) do
      Agent.get_and_update(workers, fn state ->
        {worker_pid, state} = Map.pop(state, invoke_id)
        stop_worker_pid(worker_pid)
        {:ok, state}
      end)
    end

    @spec stop_worker_pid(pid() | nil) :: :ok
    defp stop_worker_pid(nil), do: :ok
    defp stop_worker_pid(pid), do: if(Process.alive?(pid), do: Agent.stop(pid), else: :ok)

    @spec pids(pid()) :: [pid()]
    def pids(workers), do: Agent.get(workers, &Map.values(&1))
  end
end
