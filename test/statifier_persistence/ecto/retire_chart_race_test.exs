defmodule StatifierPersistence.Ecto.RetireChartRaceTest do
  @moduledoc """
  The race ADR-0012 decision 6 names: an execution created on a content
  hash after a retirement's counts were taken and before its tombstone
  is written.

  What closes it is that the tombstone is not an update the counts
  authorise. It is a single conditional `UPDATE` that re-asserts every
  blocking count of decision 1 in its own `WHERE` - no `:active`
  execution row on the hash, no position row on it, no durable-child pin
  naming it, and the row not already retired - so a pin committed before
  that statement runs is in its `NOT EXISTS` and the statement matches
  no row. A statement that matches no row is read back and reported as
  the refusal it is, rather than being taken for a write.

  These cases run live, outside the SQL sandbox, for
  `StatifierPersistence.Ecto.CallerTransactionTest`'s reason: the sandbox
  funnels every caller through one owned connection, so the second
  writer below would be waiting on connection ownership rather than
  committing beside the first. Here the two are real pooled connections
  and the second one's `COMMIT` is one the first can see.
  """

  # Its own rows, outside any sandbox: nothing here may run beside
  # another test.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.TestRepo

  @prefix "retire-race-"

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    %{store: store}
  end

  setup do
    %{content_hash: @prefix <> "#{System.unique_integer([:positive])}"}
  end

  # sabotage: in Storage.Ecto.write_tombstone/3, replace
  # unpinned_chart/2 with a query carrying only the content_hash and
  # retired_at clauses (dropping the three NOT EXISTS guards), so the
  # counts taken above it are the only guard -> red, the retirement
  # below tombstoned a chart that had acquired a live execution since
  # those counts were taken, and the last two assertions read nil blobs.
  # Verified red on this file. Reverted from a copy.
  test "an execution committed after the counts refuses the tombstone", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)

    refusal =
      TestRepo.transaction(fn ->
        # The count this caller is deciding on: nothing is running.
        assert {:ok, %{active: 0}} = Executions.executions_on(store, content_hash)

        # A second connection creates one and commits it, which is the
        # arrival the record says must not be retired out from under.
        insert_active_on_another_connection(content_hash)

        Storage.retire_chart(store, content_hash, retired_by: "ops@example.test")
      end)

    assert {:ok, {:error, {:pinned, counts}}} = refusal
    assert counts.executions.active == 1

    # Nothing was written: the bytes the refused retirement would have
    # removed are still readable, and the hash is not tombstoned.
    assert {:ok, chart} = Storage.fetch_chart(store, content_hash)
    assert chart.chart_blob == "chart-bytes"
  end

  # sabotage: in Storage.Ecto.written/4, answer {:ok, ...} for a zero
  # row count instead of reading the store back -> red, the second
  # retirement below reported success over a chart it had not written.
  # Verified red on this file. Reverted from a copy.
  test "a retirement that loses to another retirement reads the winner's tombstone", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)
    first = DateTime.from_naive!(~N[2026-09-19 18:00:00.000000], "Etc/UTC")

    assert {:ok, _retired} =
             Executions.retire_chart(store, content_hash, [],
               retired_by: "first-operator",
               now: first
             )

    assert {:error, {:chart_retired, info}} =
             Executions.retire_chart(store, content_hash, [], retired_by: "second-operator")

    assert info.retired_at == first
    assert info.retired_by == "first-operator"
  end

  # The removal itself, read off the row rather than through a door -
  # every door answers the retired arm for this hash, so this is the
  # only place the bytes can be shown to be gone.
  #
  # sabotage: in Storage.Ecto.write_tombstone/3, drop the two `nil`
  # assignments from the `set:` -> red, the row carried its
  # identity_blob and chart_blob unchanged after the retirement.
  # Verified red on this file. Reverted from a copy.
  test "the tombstoned row keeps its hash and carries no bytes", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)

    assert {:ok, _retired} =
             Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

    row = TestRepo.get_by!(Default.Chart, content_hash: content_hash)

    assert row.content_hash == content_hash
    assert row.identity_blob == nil
    assert row.chart_blob == nil
    assert row.retired_by == "ops@example.test"
  end

  defp save_chart(store, content_hash) do
    assert :ok =
             store.adapter.save_chart(store.opts, %{
               content_hash: content_hash,
               identity_blob: "identity-bytes",
               chart_blob: "chart-bytes"
             })
  end

  # A pooled connection of its own, and a commit of its own: this is the
  # writer the retirement has to see, and it has to be a different
  # connection for the seeing to mean anything.
  defp insert_active_on_another_connection(content_hash) do
    Task.async(fn ->
      TestRepo.insert!(%Default.Execution{
        execution_id: @prefix <> "#{System.unique_integer([:positive])}",
        status: "active",
        content_hash: content_hash,
        identity_blob: "identity-bytes",
        position_blob: "position-bytes",
        metadata: %{}
      })
    end)
    |> Task.await()
  end

  defp delete_prefixed do
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, ^"#{@prefix}%")))
    TestRepo.delete_all(from(c in Default.Chart, where: like(c.content_hash, ^"#{@prefix}%")))
  end
end
