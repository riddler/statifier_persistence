defmodule StatifierPersistence.Ecto.LoopLostDriveTest do
  @moduledoc """
  On Postgres under the default `AdapterLock`, a durable subchart child's
  create commits with the parent's step or not at all, so a drive that is
  lost leaves no later pass's child behind (ADR-0008's 2026-11-22
  Amendment, point 3: why routing an answer to the newest child is exact
  on this store).

  The lost drive is a caller's transaction that rolls back around the
  drive: `lock_execution/3` runs inside it (the contract
  `CallerTransactionTest` pins), so the child's insert and the parent's
  step are undone together, as they are when a drive dies before its lock
  transaction commits. Live, outside the SQL sandbox, for
  `CallerTransactionTest`'s reason: inside the sandbox the caller's
  transaction is a savepoint of the sandbox's own.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Test.LoopingSubchart
  alias StatifierPersistence.TestRepo

  @type_name "myapp:subchart"

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    %{store: store}
  end

  # sabotage: in Driver's `{:start_child, ...}` arm of perform/5, ran
  # start_child/3 inside Task.async/1 + Task.await/1 (a second pooled
  # connection, outside the step's transaction) -> red, the second pass's
  # child was still stored after the rollback. Verified red, reverted from
  # a copy.
  test "a lost drive of a loop's second pass leaves no child behind", %{store: store} do
    parent = "loop-lost-#{System.unique_integer([:positive])}"
    driver = LoopingSubchart.driver(store, @type_name)

    unresolving =
      LoopingSubchart.driver(store, @type_name, chart_resolver: fn _hash -> :error end)

    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _ms} = Driver.create(driver, parent)
    assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(unresolving, first)
    assert LoopingSubchart.children(store, parent) == [{first, :completed}]

    assert {:error, :lost} =
             TestRepo.transaction(fn ->
               {:ok, _execution, _ms} = Driver.answer_parent(driver, first, {:done, nil})

               [{^first, :completed}, {_second, :active}] =
                 LoopingSubchart.children(store, parent)

               TestRepo.rollback(:lost)
             end)

    assert LoopingSubchart.children(store, parent) == [{first, :completed}]
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewing"]

    # The answer delivered again is the first pass's, and it is taken.
    assert {:ok, _execution, _ms} = Driver.answer_parent(driver, first, {:done, nil})
    assert [{^first, :completed}, {_second, :active}] = LoopingSubchart.children(store, parent)
  end

  defp delete_prefixed do
    TestRepo.delete_all(from(i in Default.Input, where: like(i.execution_id, "loop-lost-%")))
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, "loop-lost-%")))
  end
end
