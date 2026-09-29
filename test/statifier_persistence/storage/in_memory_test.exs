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

  # sabotage: in InMemory.insert_execution/2, drop the exists-check inside
  # Agent.get_and_update/2 and always write with :ok -> red, all 25
  # concurrent inserts returned :ok instead of exactly one. Verified red
  # (together with the conformance suite's duplicate-insert test under
  # this one mutation), reverted.
  test "insert_execution/2 admits exactly one of many concurrent inserts for one execution_id" do
    {:ok, opts} = InMemory.init([])

    execution_record = %{
      execution_id: "execution-atomic",
      status: :active,
      content_hash: "sha256:lifecycle",
      identity_blob: <<1, 2, 3>>,
      position_blob: <<7, 8, 9>>,
      failure: nil
    }

    results =
      1..25
      |> Task.async_stream(fn _index -> InMemory.insert_execution(opts, execution_record) end,
        max_concurrency: 25
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :execution_exists})) == 24
  end

  describe "a write onto a tombstoned hash (ADR-0012's 2026-09-28 Amendment)" do
    # The Agent orders a retirement and a write that puts an execution on
    # its hash; the check inside the write's own transition is what keeps
    # the write that loses from landing on the tombstone.

    setup do
      {:ok, opts} = InMemory.init([])

      for content_hash <- ["sha256:loan-desk", "sha256:loan-renewed"] do
        :ok =
          InMemory.save_chart(opts, %{
            content_hash: content_hash,
            identity_blob: <<1, 2, 3>>,
            chart_blob: <<4, 5, 6>>
          })
      end

      {:ok, info} =
        InMemory.retire_chart(opts, "sha256:loan-renewed", %{
          retired_at: DateTime.from_naive!(~N[2026-09-28 18:00:00.000000], "Etc/UTC"),
          retired_by: "circulation-desk",
          sources: %{}
        })

      %{opts: opts, info: info}
    end

    defp loan(execution_id, content_hash, status \\ :active) do
      %{
        execution_id: execution_id,
        status: status,
        content_hash: content_hash,
        identity_blob: <<1, 2, 3>>,
        position_blob: <<7, 8, 9>>,
        failure: nil,
        metadata: %{},
        outcome_blob: nil,
        ended_at: nil
      }
    end

    # sabotage: in InMemory.insert_execution/2, drop the tombstone_on/2
    # clause of the cond -> red, the insert answered :ok and stored the
    # execution on the tombstoned hash. Verified red, reverted from a copy.
    test "an insert on a tombstoned hash answers the retired arm and stores nothing", %{
      opts: opts,
      info: info
    } do
      assert {:error, {:chart_retired, ^info}} =
               InMemory.insert_execution(opts, loan("loan-on-tombstone", "sha256:loan-renewed"))

      assert {:error, :execution_not_found} = InMemory.fetch_execution(opts, "loan-on-tombstone")
    end

    # sabotage: in InMemory.update_execution/2, write carry_forward/2's
    # record without asking repin_refusal/3 -> red, the re-pin answered
    # :ok and moved the execution onto the tombstoned hash. Verified red,
    # reverted from a copy.
    test "a re-pin onto a tombstoned hash answers the retired arm and leaves the row", %{
      opts: opts,
      info: info
    } do
      stored = loan("loan-repin", "sha256:loan-desk")
      :ok = InMemory.insert_execution(opts, stored)

      assert {:error, {:chart_retired, ^info}} =
               InMemory.update_execution(opts, loan("loan-repin", "sha256:loan-renewed"))

      assert {:ok, ^stored} = InMemory.fetch_execution(opts, "loan-repin")
    end

    # A write that leaves the execution on its own hash is not asked:
    # here a finished loan on the retired hash, stored before the
    # retirement, is written again on that hash.
    #
    # sabotage: in InMemory.repin_refusal/3, drop the
    # `content_hash != stored.content_hash` test -> red, the overwrite on
    # the execution's own hash answered the retired arm. Verified red,
    # reverted from a copy.
    test "an overwrite that keeps the execution on its own hash is not refused" do
      {:ok, opts} = InMemory.init([])

      :ok =
        InMemory.save_chart(opts, %{
          content_hash: "sha256:loan-returned",
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        })

      :ok =
        InMemory.insert_execution(opts, loan("loan-returned", "sha256:loan-returned", :completed))

      {:ok, _info} =
        InMemory.retire_chart(opts, "sha256:loan-returned", %{
          retired_at: DateTime.utc_now(),
          retired_by: "circulation-desk",
          sources: %{}
        })

      assert :ok =
               InMemory.update_execution(
                 opts,
                 loan("loan-returned", "sha256:loan-returned", :completed)
               )
    end

    # sabotage: in InMemory.tree_write/3, apply tree_written/2 without
    # asking tree_refusal/3 -> red, the unit answered :ok and the re-pin
    # landed on the tombstoned hash beside the park. Verified red,
    # reverted from a copy.
    test "a tree unit with a re-pin onto a tombstoned hash writes nothing", %{
      opts: opts,
      info: info
    } do
      repinned = loan("loan-tree-repin", "sha256:loan-desk")
      parked = loan("loan-tree-park", "sha256:loan-desk")
      :ok = InMemory.insert_execution(opts, repinned)
      :ok = InMemory.insert_execution(opts, parked)

      assert {:error, {:chart_retired, ^info}} =
               InMemory.write_tree_migration(opts, [
                 {:park, "loan-tree-park"},
                 {:repin, loan("loan-tree-repin", "sha256:loan-renewed"), nil}
               ])

      assert {:ok, ^repinned} = InMemory.fetch_execution(opts, "loan-tree-repin")
      assert {:ok, ^parked} = InMemory.fetch_execution(opts, "loan-tree-park")
    end
  end
end
