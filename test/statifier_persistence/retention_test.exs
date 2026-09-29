defmodule StatifierPersistence.RetentionTest do
  # Retention.prune/3 over the in-memory adapter: the batching loop, the
  # refusal for a store that cannot prune, and the argument checks. What
  # one batch selects and clears is the adapter contract, checked per
  # adapter by the conformance suite (ADR-0016).
  use ExUnit.Case, async: true

  alias Statifier.MachineState
  alias StatifierPersistence.Retention
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.InputLogAdapter
  alias StatifierPersistence.Testing.Charts

  @cutoff ~U[2026-02-01 00:00:00.000000Z]

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  # sabotage: made prune_batches/4 stop after the first batch whatever
  # it answered -> red, the total counted two executions of the five due.
  # Verified red, reverted from a copy.
  test "prune/3 sums every batch until nothing ended before the cutoff is left", %{store: store} do
    for day <- 1..5, do: execution(store, "retention-due-#{day}", :completed, day)
    execution(store, "retention-active", :active, nil)
    execution(store, "retention-after", :completed, 40)

    assert {:ok, %{executions: 5, position_blobs: 5, inputs: 0}} =
             Retention.prune(store, @cutoff, batch_size: 2)

    for day <- 1..5 do
      assert {:ok, %{position_blob: nil, status: :completed}} =
               Storage.fetch_execution(store, "retention-due-#{day}")
    end

    for id <- ["retention-active", "retention-after"] do
      assert {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, id)
      assert is_binary(blob)
    end

    assert {:ok, %{executions: 0, position_blobs: 0, inputs: 0}} =
             Retention.prune(store, @cutoff, batch_size: 2)
  end

  # sabotage: removed the capability check from
  # Storage.prune_executions/4 -> red, the facade called a callback the
  # adapter does not export. Removing prune/3's own check alone stays
  # green, because the facade answers the same refusal. Verified, reverted
  # from a copy.
  test "prune/3 refuses a store whose adapter does not declare pruning" do
    {:ok, store} = Storage.new(InputLogAdapter, [])

    refute Storage.execution_pruning_supported?(store)

    assert {:error, :execution_pruning_unsupported} = Retention.prune(store, @cutoff)

    assert {:error, :execution_pruning_unsupported} =
             Storage.prune_executions(store, @cutoff, 10)
  end

  # sabotage: widened prune/3's first clause to accept any cutoff -> red,
  # the integer and the Date reached the facade's guard and raised
  # FunctionClauseError rather than this ArgumentError. Verified red,
  # reverted from a copy.
  test "prune/3 takes a DateTime cutoff and never a duration", %{store: store} do
    for cutoff <- [30, Duration.new!(day: 30), ~D[2026-02-01], "2026-02-01"] do
      assert_raise ArgumentError, ~r/DateTime/, fn -> Retention.prune(store, cutoff) end
    end
  end

  # sabotage: made batch_size!/1 return any value it was given -> red,
  # 0 reached the facade's guard and raised FunctionClauseError instead.
  # Verified red, reverted from a copy.
  test "prune/3 refuses a batch size that is not a positive integer", %{store: store} do
    for size <- [0, -1, 1.5, :all] do
      assert_raise ArgumentError, ~r/batch_size/, fn ->
        Retention.prune(store, @cutoff, batch_size: size)
      end
    end
  end

  # sabotage: made InMemory's prune_executions/4 ignore its scope and
  # prune as if unscoped -> red, the answer was {:ok, counts} and the
  # position was cleared. Verified red, reverted from a copy.
  test "prune/3 with a scope answers :unscoped_adapter from an adapter that cannot confine it",
       %{store: store} do
    execution(store, "retention-scoped", :completed, 1)

    assert {:error, :unscoped_adapter} =
             Retention.prune(store, @cutoff, scope: [tenant_id: "tenant-a"])

    assert {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, "retention-scoped")
    assert is_binary(blob)

    assert {:ok, %{executions: 1}} = Retention.prune(store, @cutoff)
  end

  # sabotage: made scope!/1 return any value it was given -> red, [] and
  # the nil value reached the adapter and pruned or answered instead of
  # raising. Verified red, reverted from a copy.
  test "prune/3 refuses a scope that is not a non-empty keyword list of set columns",
       %{store: store} do
    for scope <- [
          [],
          %{tenant_id: "tenant-a"},
          "tenant-a",
          [{"tenant_id", "tenant-a"}],
          [tenant_id: nil],
          [tenant_id: "tenant-a", tenant_id: "tenant-b"]
        ] do
      assert_raise ArgumentError, ~r/scope/, fn ->
        Retention.prune(store, @cutoff, scope: scope)
      end
    end
  end

  # sabotage: made the single-batch path call prune_batches/5 instead of
  # one Storage.prune_executions/4 call -> red, the first call answered
  # all five executions and more?: false instead of stopping at two.
  # Verified red, reverted from a copy.
  test "prune/3 with single_batch: true answers one batch's counts plus more?", %{store: store} do
    for day <- 1..5, do: execution(store, "single-due-#{day}", :completed, day)

    assert {:ok, %{executions: 2, position_blobs: 2, inputs: 0, more?: true}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    remaining =
      for day <- 1..5,
          {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, "single-due-#{day}"),
          is_binary(blob),
          do: day

    assert length(remaining) == 3

    assert {:ok, %{executions: 2, position_blobs: 2, inputs: 0, more?: true}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    assert {:ok, %{executions: 1, position_blobs: 1, inputs: 0, more?: false}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    assert {:ok, %{executions: 0, position_blobs: 0, inputs: 0, more?: false}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)
  end

  # sabotage: made prune_one_batch/4 answer more?: counts.executions >
  # batch_size -> red, the first call answered more?: false for a full
  # batch. Verified red, reverted from a copy.
  #
  # No mutant of a stateless more? rule - one computed from the batch's
  # executions count and batch_size alone - is killed by this test and
  # not by the five-by-two test above. That test already asks the rule
  # for (2, 2) -> true, (1, 2) -> false and (0, 2) -> false; this one
  # asks only (2, 2) -> true and (0, 2) -> false, a subset, so any rule
  # the test above accepts, this one accepts too (> batch_size fails
  # both; >= batch_size passes both, equal to == while a batch never
  # takes more than batch_size; > 0 fails only the test above).
  #
  # What this test adds is the rule's kind: more? says only that the
  # batch was full, never that something due remains. The mutant only it
  # kills reads the store instead - made prune_one_batch/4 answer more?:
  # true when any execution still due is left after the batch -> red
  # here, the second call answered more?: false for a full last batch,
  # while the test above stays green (3, 1, 0 and 0 due left match its
  # true, true, false, false). Verified red, reverted from a copy.
  test "prune/3 with single_batch: true answers more?: true for an exactly-full last batch, then zeros",
       %{store: store} do
    for day <- 1..4, do: execution(store, "full-due-#{day}", :completed, day)

    assert {:ok, %{executions: 2, position_blobs: 2, inputs: 0, more?: true}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    assert {:ok, %{executions: 2, position_blobs: 2, inputs: 0, more?: true}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    assert {:ok, %{executions: 0, position_blobs: 0, inputs: 0, more?: false}} =
             Retention.prune(store, @cutoff, single_batch: true, batch_size: 2)

    for day <- 1..4 do
      assert {:ok, %{position_blob: nil}} = Storage.fetch_execution(store, "full-due-#{day}")
    end
  end

  # sabotage: made single_batch!/1 return its input unchanged -> red, no
  # ArgumentError was raised; each value reached the prune as truthy or
  # falsy. Verified red, reverted from a copy.
  test "prune/3 refuses a single_batch that is not a boolean", %{store: store} do
    for value <- [1, :yes, nil, "true"] do
      assert_raise ArgumentError, ~r/single_batch/, fn ->
        Retention.prune(store, @cutoff, single_batch: value)
      end
    end
  end

  # sabotage: made prune/3 always put :more? on the answer, even for
  # single_batch: false -> red, the assertion that the key is absent
  # failed. Verified red, reverted from a copy.
  test "prune/3 with single_batch: false answers exactly today's map", %{store: store} do
    for day <- 1..3, do: execution(store, "plain-due-#{day}", :completed, day)

    assert {:ok, counts} = Retention.prune(store, @cutoff, single_batch: false)
    refute Map.has_key?(counts, :more?)
    assert counts == %{executions: 3, position_blobs: 3, inputs: 0}

    assert {:ok, default_counts} = Retention.prune(store, @cutoff)
    refute Map.has_key?(default_counts, :more?)
  end

  # One execution in `status`, stored with a position, stamped on day
  # `day` of 2026-01 when it is terminal.
  defp execution(store, execution_id, status, day) do
    {_source, machine} = Charts.chart_a()
    machine_state = MachineState.new(machine, session_id: "sess_" <> execution_id)

    stamp =
      case day do
        nil -> DateTime.utc_now()
        day -> DateTime.add(~U[2026-01-01 00:00:00.000000Z], day - 1, :day)
      end

    :ok = Storage.insert_execution(store, execution_id, machine_state, status, [], stamp)
  end
end
