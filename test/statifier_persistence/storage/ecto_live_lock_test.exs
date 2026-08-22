defmodule StatifierPersistence.Storage.EctoLiveLockTest do
  # Live lock tests run outside the SQL sandbox, like the live migration
  # tests: the sandbox funnels every caller through one shared
  # connection, which serializes transactions by ownership alone and
  # would mask a broken lock. Here each task takes its own pooled
  # connection, so the exclusion observed is the database's - the
  # advisory lock and the row lock - not connection scheduling.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.Storage
  alias StatifierPersistence.TestRepo

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    on_exit(fn ->
      TestRepo.delete_all(Default.Run)
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, opts} = Storage.Ecto.init(persistence: Default)
    %{opts: opts}
  end

  defp assert_no_overlap(opts, run_id) do
    {:ok, events} = Agent.start_link(fn -> [] end)

    body = fn tag ->
      fn ->
        Agent.update(events, &[{:enter, tag} | &1])
        Process.sleep(50)
        Agent.update(events, &[{:exit, tag} | &1])
        tag
      end
    end

    tasks =
      for tag <- [:first, :second] do
        Task.async(fn -> Storage.Ecto.lock_run(opts, run_id, body.(tag)) end)
      end

    assert [{:ok, _tag_a}, {:ok, _tag_b}] = Task.await_many(tasks, 10_000)

    recorded = events |> Agent.get(& &1) |> Enum.reverse()
    assert [{:enter, one}, {:exit, one}, {:enter, other}, {:exit, other}] = recorded
    assert one != other
  end

  # sabotage: replaced lock_run/3's transaction body with a bare
  # {:ok, fun.()} (no advisory lock, no row lock, no transaction) ->
  # red, the two sleeping bodies interleaved on separate pool
  # connections and the paired enter/exit pattern broke. Verified red
  # (this test and the rowless one below under the one mutation),
  # reverted.
  test "two connections never overlap on an inserted run's lock", %{opts: opts} do
    :ok =
      Storage.Ecto.insert_run(opts, %{
        run_id: "run-live-lock-row",
        status: :active,
        content_hash: "sha256:live-lock",
        identity_blob: <<1>>,
        position_blob: nil,
        failure: nil
      })

    assert_no_overlap(opts, "run-live-lock-row")
  end

  # sabotage: dropped the pg_advisory_xact_lock query, leaving only the
  # SELECT ... FOR UPDATE row lock -> red on this test alone: with no
  # row to lock, the two bodies interleaved (while the inserted-run
  # test above stayed green on its row lock). The exact hole the
  # ADR-0004 amendment exists for. Verified red, reverted.
  test "two connections never overlap on a rowless run_id", %{opts: opts} do
    assert_no_overlap(opts, "run-live-lock-rowless")
  end

  # sabotage: same bare {:ok, fun.()} mutation as above -> this test
  # alone stayed green (nothing held means nothing leaks), which is why
  # it exists alongside the overlap tests, not instead of them: it pins
  # the release-on-raise contract while they pin the exclusion. Under
  # the real implementation a leaked transaction-scoped lock would park
  # the reacquisition until the pool's checkout timeout instead of
  # answering within the yield window.
  test "a raising fun releases the lock for the next caller", %{opts: opts} do
    assert_raise RuntimeError, "live lock boom", fn ->
      Storage.Ecto.lock_run(opts, "run-live-lock-raise", fn ->
        raise "live lock boom"
      end)
    end

    task =
      Task.async(fn ->
        Storage.Ecto.lock_run(opts, "run-live-lock-raise", fn -> :reacquired end)
      end)

    assert {:ok, {:ok, :reacquired}} = Task.yield(task, 5_000) || Task.shutdown(task)
  end
end
