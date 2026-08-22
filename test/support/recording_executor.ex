defmodule StatifierPersistence.Test.RecordingExecutor do
  @moduledoc """
  An Agent-backed `StatifierPersistence.Executor` implementation that
  records every `{effect, context}` pair it receives, in call order, and
  always answers `:ok`.

  Registered under this module's own name, so `execute/2` needs no handle
  beyond the behaviour's own arguments. Start it per test with
  `start_supervised!/1`; tests within one module run serially, so the
  single name never collides.
  """

  @behaviour StatifierPersistence.Executor

  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl StatifierPersistence.Executor
  def execute(effect, context) do
    Agent.update(__MODULE__, &[{effect, context} | &1])
    :ok
  end

  @doc "Every recorded `{effect, context}` pair, oldest first."
  @spec calls() :: [{Statifier.Effect.t(), StatifierPersistence.Executor.context()}]
  def calls do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @doc "Every recorded effect, oldest first."
  @spec effects() :: [Statifier.Effect.t()]
  def effects do
    Enum.map(calls(), fn {effect, _context} -> effect end)
  end

  @doc "Drops everything recorded so far."
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _recorded -> [] end)
  end
end
