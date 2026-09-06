defmodule StatifierPersistence.Test.LockOrderRecorder do
  @moduledoc """
  A `StatifierPersistence.Serialization` strategy that reports, for every
  exclusion it opens, which exclusions the calling process was *already*
  holding when it asked for this one - the real
  `StatifierPersistence.Serialization.AdapterLock` exclusion runs unchanged
  inside it.

  The fixture for sp-oq4's audit. A deadlock between two connections needs
  a cycle in the "holds X, waits for Y" relation, so the only thing that
  has to be pinned is the direction every nested acquisition runs in. This
  records exactly that and judges nothing: it sends
  `{:acquire, run_id, held}` before the inner exclusion opens and
  `{:release, run_id, held}` after it closes, where `held` is the list of
  run ids whose exclusions this process has open at that moment, innermost
  first.

  A test reads the direction straight off `held`: an acquisition whose
  `held` are all strict ancestors of `run_id` (`Run.Linkage.child_run_id/3`
  makes a child's id strictly extend its parent's) can only ever wait on a
  run further down the same tree, and a relation that only ever runs
  parent-to-child over an acyclic tree has no cycle to find.

  The held list lives in the process dictionary because that is what a
  connection's lock set is scoped to: `Storage.Ecto.lock_run/3` nests as
  one transaction on one checked-out connection, so per-process is
  per-connection. It is restored in an `after`, so a raise inside the
  exclusion unwinds the record with it.

  `config` is `{test_pid, StatifierPersistence.Storage.t()}`.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Serialization.AdapterLock

  @held_key {__MODULE__, :held}

  @impl StatifierPersistence.Serialization
  @spec with_run(config :: term(), run_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_run({test_pid, store}, run_id, fun) do
    held = Process.get(@held_key, [])
    send(test_pid, {:acquire, run_id, held})
    Process.put(@held_key, [run_id | held])

    try do
      AdapterLock.with_run(store, run_id, fun)
    after
      Process.put(@held_key, held)
      send(test_pid, {:release, run_id, held})
    end
  end

  @doc """
  Drains this process's mailbox of the `{:acquire, _, _}` and
  `{:release, _, _}` messages `with_run/3` sent, in the order they were
  sent.

  Every driver a test hands this strategy runs in the test process itself,
  so the mailbox order is the acquisition order.
  """
  @spec trace() :: [{:acquire | :release, String.t(), [String.t()]}]
  def trace do
    receive do
      {event, run_id, held} when event in [:acquire, :release] ->
        [{event, run_id, held} | trace()]
    after
      0 -> []
    end
  end
end
