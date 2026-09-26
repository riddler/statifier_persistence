defmodule StatifierPersistence.Test.RecordingExecutor do
  @moduledoc """
  An Agent-backed `StatifierPersistence.Executor` implementation that
  records every `{effect, context}` pair it receives, in call order, and
  always answers `:ok`.

  Each test starts its own recorder with `start!/0` from its `setup`. The
  Agent is started under the test's supervisor with no registered name,
  so async test modules never share one or collide on a name. `start!/0`
  keeps the Agent's pid in the test process's dictionary, and `execute/2`,
  `calls/0`, `effects/0` and `reset/0` find it there: in the calling
  process itself, or in the first process on its `$callers` chain that
  started one (a `Task` spawned by the test finds the test's recorder).
  So the module still passes as `executor: RecordingExecutor`, needing no
  handle beyond the behaviour's own arguments.
  """

  @behaviour StatifierPersistence.Executor

  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end)
  end

  @doc """
  Starts this test's recorder under the test supervisor and makes it the
  one the calling test process (and the processes it spawns) records to.
  Call it from `setup` or from the test body; it returns the Agent's pid.
  """
  @spec start!() :: pid()
  def start! do
    recorder = ExUnit.Callbacks.start_supervised!(__MODULE__)
    Process.put(__MODULE__, recorder)
    recorder
  end

  @impl StatifierPersistence.Executor
  def execute(effect, context) do
    Agent.update(recorder!(), &[{effect, context} | &1])
    :ok
  end

  @doc "Every recorded `{effect, context}` pair, oldest first."
  @spec calls() :: [{Statifier.Effect.t(), StatifierPersistence.Executor.context()}]
  def calls do
    Agent.get(recorder!(), &Enum.reverse/1)
  end

  @doc "Every recorded effect, oldest first."
  @spec effects() :: [Statifier.Effect.t()]
  def effects do
    Enum.map(calls(), fn {effect, _context} -> effect end)
  end

  @doc "Drops everything recorded so far."
  @spec reset() :: :ok
  def reset do
    Agent.update(recorder!(), fn _recorded -> [] end)
  end

  defp recorder! do
    Enum.find_value([self() | Process.get(:"$callers", [])], &recorder_of/1) ||
      raise "no RecordingExecutor started for this test process or its callers; " <>
              "call RecordingExecutor.start!/0 in the test's setup"
  end

  defp recorder_of(pid) when pid == self(), do: Process.get(__MODULE__)

  defp recorder_of(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, __MODULE__, 0) do
          {__MODULE__, recorder} -> recorder
          nil -> nil
        end

      nil ->
        nil
    end
  end
end
