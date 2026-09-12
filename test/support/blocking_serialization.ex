defmodule StatifierPersistence.Test.BlockingSerialization do
  @moduledoc """
  A `StatifierPersistence.Serialization` strategy that pauses `with_execution/3`
  on entry - before it delegates to the real per-execution exclusion
  (`StatifierPersistence.Serialization.AdapterLock`) and runs the tail -
  until the test process releases it.

  The fixture for `driver_restart_race_test.exs`'s "child completes while
  the parent is mid-restart" case (ADR-0008 decision 5): it signals
  `{:entered, self()}` to the configured test process the moment
  `with_execution/3` is entered, then blocks on a `:go_ahead` message before
  acquiring the real lock and running `fun`. This holds the answering
  step open at the exact point right before the real exclusion - and the
  liveness read taken inside it - begins, so a second process's write can
  land in the gap on purpose. Whether that gap is safe is the question
  the test answers.

  `config` is `{test_pid, StatifierPersistence.Storage.t()}`.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Serialization.AdapterLock

  @impl StatifierPersistence.Serialization
  @spec with_execution(config :: term(), execution_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_execution({test_pid, store}, execution_id, fun) do
    send(test_pid, {:entered, self()})

    receive do
      :go_ahead -> :ok
    end

    AdapterLock.with_execution(store, execution_id, fun)
  end
end
