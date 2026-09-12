defmodule StatifierPersistence.Test.LockOrderRecorder do
  @moduledoc """
  A `StatifierPersistence.Serialization` strategy that reports, for every
  exclusion it opens, which exclusions the calling process was *already*
  holding when it asked for this one - the real
  `StatifierPersistence.Serialization.AdapterLock` exclusion executions unchanged
  inside it.

  The fixture for sp-oq4's audit. A deadlock between two connections needs
  a cycle in the "holds X, waits for Y" relation, so the only thing that
  has to be pinned is the direction every nested acquisition executions in. This
  records exactly that and judges nothing: it sends
  `{:acquire, execution_id, held}` before the inner exclusion opens and
  `{:release, execution_id, held}` after it closes, where `held` is the list of
  execution ids whose exclusions this process has open at that moment, innermost
  first.

  A test reads the direction straight off `held`: an acquisition whose
  `held` are all strict ancestors of `execution_id` (`Execution.Linkage.child_execution_id/3`
  makes a child's id strictly extend its parent's) can only ever wait on a
  execution further down the same tree, and a relation that only ever executions
  parent-to-child over an acyclic tree has no cycle to find.

  The held list lives in the process dictionary because that is what a
  connection's lock set is scoped to: `Storage.Ecto.lock_execution/3` nests as
  one transaction on one checked-out connection, so per-process is
  per-connection. It is restored in an `after`, so a raise inside the
  exclusion unwinds the record with it.

  `config` is `{test_pid, StatifierPersistence.Storage.t()}`.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Serialization.AdapterLock

  @held_key {__MODULE__, :held}

  @impl StatifierPersistence.Serialization
  @spec with_execution(config :: term(), execution_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_execution({test_pid, store}, execution_id, fun) do
    held = Process.get(@held_key, [])
    send(test_pid, {:acquire, execution_id, held})
    Process.put(@held_key, [execution_id | held])

    try do
      AdapterLock.with_execution(store, execution_id, fun)
    after
      Process.put(@held_key, held)
      send(test_pid, {:release, execution_id, held})
    end
  end

  @doc """
  Drains this process's mailbox of the `{:acquire, _, _}` and
  `{:release, _, _}` messages `with_execution/3` sent, in the order they were
  sent.

  Every driver a test hands this strategy runs in the test process itself,
  so the mailbox order is the acquisition order.
  """
  @spec trace() :: [{:acquire | :release, String.t(), [String.t()]}]
  def trace do
    receive do
      {event, execution_id, held} when event in [:acquire, :release] ->
        [{event, execution_id, held} | trace()]
    after
      0 -> []
    end
  end
end
