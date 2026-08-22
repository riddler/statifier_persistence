defmodule StatifierPersistence.Storage.InMemoryTest do
  use ExUnit.Case

  alias StatifierPersistence.Storage.InMemory

  # The conformance suite (test/statifier_persistence/storage/in_memory_conformance_test.exs,
  # via StatifierPersistence.Testing.StorageConformance) covers every
  # adapter-callback assertion this module used to make - round trips,
  # idempotence, not-found arms, byte-identity - across every adapter,
  # InMemory included. What is left here is genuinely specific to this
  # adapter's own implementation: its Agent lifecycle.

  # sabotage: in InMemory.init/1, return {:ok, opts} unchanged instead of
  # merging in :pid -> red, this test's Keyword.fetch!(opts, :pid) raised
  # KeyError instead of returning a pid. Verified red, reverted (this
  # mutation also took out most of the conformance suite, since every
  # adapter call in it threads opts through init/1's :pid).
  test "init/1 starts an Agent and returns its pid under :pid" do
    assert {:ok, opts} = InMemory.init([])

    pid = Keyword.fetch!(opts, :pid)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  # sabotage: in InMemory.init/1, seed the new Agent's state with a chart
  # already present under "sha256:lifecycle" instead of starting from
  # %{charts: %{}, positions: %{}} -> red, the fetch_chart/2 call below on
  # second_opts (a distinct Agent, started after the first) found the
  # seeded chart instead of reporting :chart_not_found. Verified red,
  # reverted.
  test "each init/1 call starts an independent Agent with its own state" do
    {:ok, first_opts} = InMemory.init([])
    {:ok, second_opts} = InMemory.init([])

    refute Keyword.fetch!(first_opts, :pid) == Keyword.fetch!(second_opts, :pid)

    chart_record = %{
      content_hash: "sha256:lifecycle",
      identity_blob: <<1, 2, 3>>,
      chart_blob: <<4, 5, 6>>
    }

    assert :ok = InMemory.save_chart(first_opts, chart_record)
    assert {:error, :chart_not_found} = InMemory.fetch_chart(second_opts, "sha256:lifecycle")
  end

  # sabotage: in InMemory.insert_run/2, drop the exists-check inside
  # Agent.get_and_update/2 and always write with :ok -> red, all 25
  # concurrent inserts returned :ok instead of exactly one. Verified red
  # (together with the conformance suite's duplicate-insert test under
  # this one mutation), reverted.
  test "insert_run/2 admits exactly one of many concurrent inserts for one run_id" do
    {:ok, opts} = InMemory.init([])

    run_record = %{
      run_id: "run-atomic",
      status: :active,
      content_hash: "sha256:lifecycle",
      identity_blob: <<1, 2, 3>>,
      position_blob: <<7, 8, 9>>,
      failure: nil
    }

    results =
      1..25
      |> Task.async_stream(fn _index -> InMemory.insert_run(opts, run_record) end,
        max_concurrency: 25
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :run_exists})) == 24
  end
end
