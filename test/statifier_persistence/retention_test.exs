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
  # Storage.prune_executions/3 -> red, the facade called a callback the
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
