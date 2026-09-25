defmodule StatifierPersistence.Ecto.ScopedPruneTest do
  # A scoped prune on the Ecto adapter, past what the conformance case
  # proves: the scope reaches the input log check and the input log
  # delete as well as the selection, `Retention.prune/3` carries it to
  # every batch, and a column that is not a leading column is refused
  # before any statement runs (ADR-0016, as amended for scoped pruning).
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL
  alias Statifier.MachineState
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Retention
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Test.ScopePlacement
  alias StatifierPersistence.Testing.Charts
  alias StatifierPersistence.TestRepo

  @cutoff ~U[2026-02-01 00:00:00.000000Z]
  @ended ~U[2026-01-01 00:00:00.000000Z]
  @tenant_a [tenant_id: "tenant-a"]
  @tenant_b [tenant_id: "tenant-b"]

  setup do
    {:ok, store} =
      Storage.new(Storage.Ecto, persistence: EctoHosts.Scoped, sandbox: true)

    :ok = Storage.Ecto.isolate(store.opts)
    %{store: store}
  end

  # sabotage: made Retention.prune/3 pass [] to every batch in place of
  # its scope -> red, tenant-b's executions were pruned too. Verified
  # red, reverted from a copy.
  test "Retention.prune/3 carries the scope to every batch", %{store: store} do
    for n <- 1..3, do: finished(store, "scoped-a-#{n}", @tenant_a)
    for n <- 1..2, do: finished(store, "scoped-b-#{n}", @tenant_b)

    assert {:ok, %{executions: 3, position_blobs: 3, inputs: 3}} =
             Retention.prune(store, @cutoff, batch_size: 2, scope: @tenant_a)

    for n <- 1..2 do
      assert {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, "scoped-b-#{n}")
      assert is_binary(blob)
      assert {:ok, [_entry]} = Storage.Ecto.list_inputs(store.opts, "scoped-b-#{n}")
    end
  end

  # sabotage: dropped `scoped/3` from the input log delete in the Ecto
  # adapter's prune_batch/4 -> red, the row stamped tenant-b was deleted
  # with its execution's others. Verified red, reverted from a copy.
  test "the input log delete carries the scope", %{store: store} do
    finished(store, "scoped-split", @tenant_a)
    append(store, "scoped-split", 1)
    restamp_input(store, "scoped-split", 1, "tenant-b")

    assert {:ok, %{executions: 1, position_blobs: 1, inputs: 1}} =
             Storage.prune_executions(store, @cutoff, 10, @tenant_a)

    assert {:ok, [%{seq: 1}]} = Storage.Ecto.list_inputs(store.opts, "scoped-split")
  end

  # sabotage: dropped `scoped/3` from the input log check inside the Ecto
  # adapter's due_executions/4 -> red, the execution was selected for a
  # log row outside the scope. Verified red, reverted from a copy.
  test "the input log check inside the selection carries the scope", %{store: store} do
    finished(store, "scoped-blobless", @tenant_a)
    restamp_input(store, "scoped-blobless", 0, "tenant-b")

    SQL.query!(
      TestRepo,
      ~s(UPDATE "scoped"."statifier_executions" SET position_blob = NULL WHERE execution_id = $1),
      ["scoped-blobless"]
    )

    assert {:ok, %{executions: 0, position_blobs: 0, inputs: 0}} =
             Storage.prune_executions(store, @cutoff, 10, @tenant_a)

    assert {:ok, %{executions: 1, position_blobs: 0, inputs: 1}} =
             Storage.prune_executions(store, @cutoff, 10, [])
  end

  # sabotage: made check_scope!/2 answer :ok for every scope -> red, the
  # unknown column reached Postgres and raised Postgrex.Error instead.
  # Verified red, reverted from a copy.
  test "a column that is not a leading column raises before any statement", %{store: store} do
    finished(store, "scoped-unknown", @tenant_a)

    assert_raise ArgumentError, ~r/:leading_columns/, fn ->
      Storage.prune_executions(store, @cutoff, 10, branch_id: 7)
    end

    {:ok, default} =
      Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)

    assert_raise ArgumentError, ~r/:leading_columns/, fn ->
      Storage.prune_executions(default, @cutoff, 10, @tenant_a)
    end

    assert {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, "scoped-unknown")
    assert is_binary(blob)
  end

  # One :completed execution that ended on @ended, with one input log row
  # at seq 0, every row of it placed in `scope`.
  defp finished(store, execution_id, scope) do
    {_source, machine} = Charts.chart_a()
    machine_state = MachineState.new(machine, session_id: "sess_" <> execution_id)
    :ok = Storage.insert_execution(store, execution_id, machine_state, :completed, [], @ended)
    append(store, execution_id, 0)
    :ok = ScopePlacement.place(store.opts, execution_id, scope)
  end

  defp append(store, execution_id, seq) do
    {:ok, _seq} =
      Storage.Ecto.append_input(store.opts, execution_id, %{
        execution_id: execution_id,
        seq: seq,
        door: "step",
        input_blob: <<seq>>
      })
  end

  defp restamp_input(_store, execution_id, seq, tenant) do
    SQL.query!(
      TestRepo,
      ~s(UPDATE "scoped"."statifier_inputs" SET tenant_id = $1 WHERE execution_id = $2 AND seq = $3),
      [tenant, execution_id, seq]
    )
  end
end
