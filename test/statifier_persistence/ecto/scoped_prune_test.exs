defmodule StatifierPersistence.Ecto.ScopedPruneTest do
  # A scoped prune on the Ecto adapter, past what the conformance case
  # proves: the scope reaches the input log check, the input log delete
  # and the position blob update as well as the selection,
  # `Retention.prune/3` carries it to every batch, and a column that is
  # not a leading column is refused before any statement runs (ADR-0016,
  # as amended for scoped pruning).
  #
  # Also covers the single-batch path (`single_batch: true`): a scoped
  # loop of `prune/3` calls, each inside its own transaction, and a call
  # inside a caller's transaction that rolls back.
  #
  # These cases run on Postgres only, by decision: scoped coverage off
  # Postgres is not wanted. The scoped arm adds no adapter-conditional
  # code: `prune_source/3` reads the tables by name and `scoped/2` adds one
  # equality per column, both adapter-neutral queries. The prune's one
  # adapter branch, the row lock in `due_executions/4`, does not depend on
  # the scope, and the SQLite repo's unscoped prune case in
  # `sqlite_migrations_test.exs` already runs it off Postgres. ADR-0005
  # decision 2 keeps the storage harness on Postgres, and the SQLite repo
  # backs only what Postgres cannot show; a scoped SQLite host would add
  # its own tables and DDL to prove nothing that case does not.
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

  # sabotage: dropped `scoped/2` from the input log delete in the Ecto
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

  # sabotage: dropped `scoped/2` from the input log check inside the Ecto
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

  # sabotage: made Retention.prune/3's single-batch path pass [] to the
  # facade in place of its scope -> red, the first loop iteration cleared
  # both tenants at once and the second answered zeros with more?: false
  # instead of the tenant-a-only 2/1 split. Verified red, reverted from a
  # copy.
  test "Retention.prune/3 with single_batch: true carries the scope to each batch, each in its own transaction",
       %{store: store} do
    for n <- 1..3, do: finished(store, "single-scoped-a-#{n}", @tenant_a)
    for n <- 1..2, do: finished(store, "single-scoped-b-#{n}", @tenant_b)

    answers = drain_in_own_transactions(store, @cutoff, @tenant_a, [])

    assert [
             %{executions: 2, position_blobs: 2, inputs: 2, more?: true},
             %{executions: 1, position_blobs: 1, inputs: 1, more?: false}
           ] = answers

    for n <- 1..2 do
      assert {:ok, %{position_blob: blob}} =
               Storage.fetch_execution(store, "single-scoped-b-#{n}")

      assert is_binary(blob)
      assert {:ok, [_entry]} = Storage.Ecto.list_inputs(store.opts, "single-scoped-b-#{n}")
    end
  end

  # sabotage: not run - no lib mutation reaches this under the SQL
  # sandbox, where every connection the test owns is already inside one
  # transaction. It pins the documented behaviour of the Ecto adapter's
  # batch transaction joining a caller's (storage/ecto.ex,
  # prune_executions/4): the caller's rollback undoes every batch.
  test "prune/3 inside a caller's transaction that rolls back leaves every batch undone",
       %{store: store} do
    for n <- 1..2, do: finished(store, "rollback-a-#{n}", @tenant_a)

    assert {:error, :undo} =
             TestRepo.transaction(fn ->
               {:ok, _counts} =
                 Retention.prune(store, @cutoff, batch_size: 1, scope: @tenant_a)

               TestRepo.rollback(:undo)
             end)

    for n <- 1..2 do
      assert {:ok, %{position_blob: blob}} = Storage.fetch_execution(store, "rollback-a-#{n}")
      assert is_binary(blob)
      assert {:ok, [_entry]} = Storage.Ecto.list_inputs(store.opts, "rollback-a-#{n}")
    end
  end

  # The package's own migration makes `execution_id` unique, so no row
  # outside the scope can share an id the selection chose. A host that
  # partitions by its leading column keys that uniqueness on the column
  # and the id instead, and there two partitions can hold one id. The
  # `SharedIdScoped` host's executions table is that table, built once by
  # the suite's bootstrap, so this test runs no DDL: dropping the index on
  # `Scoped`'s table inside the sandbox transaction held an exclusive
  # lock the async scoped conformance module, which shares that table,
  # waited on. The test copies the execution's row into tenant-b under
  # the same id with one INSERT ... SELECT.
  #
  # sabotage: dropped `scoped/2` from the position blob update in the
  # Ecto adapter's prune_batch/4 -> red, the batch cleared two blobs,
  # the tenant-b row's with the tenant-a row's. Verified red, reverted
  # from a copy.
  test "the position blob update carries the scope" do
    {:ok, store} =
      Storage.new(Storage.Ecto, persistence: EctoHosts.SharedIdScoped, sandbox: true)

    finished(store, "scoped-shared", @tenant_a)

    SQL.query!(
      TestRepo,
      """
      INSERT INTO "scoped_shared_id"."statifier_executions"
      SELECT (jsonb_populate_record(e, to_jsonb(e) || jsonb_build_object('id', e.id || '-b', 'tenant_id', 'tenant-b'))).*
      FROM "scoped_shared_id"."statifier_executions" e
      WHERE execution_id = $1
      """,
      ["scoped-shared"]
    )

    assert {:ok, %{executions: 1, position_blobs: 1, inputs: 1}} =
             Storage.prune_executions(store, @cutoff, 10, @tenant_a)

    assert %{rows: rows} =
             SQL.query!(
               TestRepo,
               ~s(SELECT tenant_id, position_blob IS NULL FROM "scoped_shared_id"."statifier_executions" WHERE execution_id = $1 ORDER BY tenant_id),
               ["scoped-shared"]
             )

    assert rows == [["tenant-a", true], ["tenant-b", false]]
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

  # Loops `Retention.prune/3` with `single_batch: true`, each call inside
  # its own transaction, collecting each batch's answer until `more?` is
  # false.
  defp drain_in_own_transactions(store, cutoff, scope, acc) do
    {:ok, answer} =
      TestRepo.transaction(fn ->
        {:ok, counts} =
          Retention.prune(store, cutoff, batch_size: 2, scope: scope, single_batch: true)

        counts
      end)

    acc = acc ++ [answer]
    if answer.more?, do: drain_in_own_transactions(store, cutoff, scope, acc), else: acc
  end

  defp restamp_input(_store, execution_id, seq, tenant) do
    SQL.query!(
      TestRepo,
      ~s(UPDATE "scoped"."statifier_inputs" SET tenant_id = $1 WHERE execution_id = $2 AND seq = $3),
      [tenant, execution_id, seq]
    )
  end
end
