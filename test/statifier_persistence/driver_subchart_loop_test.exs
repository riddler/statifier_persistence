defmodule StatifierPersistence.DriverSubchartLoopTest do
  @moduledoc """
  A durable subchart inside a loop, on the in-memory adapter (ADR-0008's
  2026-11-22 Amendment): every pass of the same `<invoke>` element starts
  a child of its own, in order, and an at-least-once re-drive of one pass
  adopts that pass's child. `driver_subchart_ecto_test.exs` and
  `ecto/sqlite_migrations_test.exs` carry the same drive on Postgres and
  on SQLite with the linkage columns on.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.LoopingSubchart

  @type_name "myapp:subchart"

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  # sabotage: in Driver's first_child/2, adopted a child at the first id
  # whatever its status (the 0.26.0 rule) -> red, the second pass adopted
  # the first pass's completed child and no second child was created.
  # Verified red, reverted from a copy.
  test "two passes start two children with distinct ids, in order, and the parent goes on", %{
    store: store
  } do
    parent = "execution_loan_renewals_1"
    driver = LoopingSubchart.driver(store, @type_name)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
    assert LoopingSubchart.children(store, parent) == [{first, :active}]

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)

    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)
    assert String.starts_with?(second, first <> "@")
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewing"]

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, second)

    assert [{^first, :completed}, {^second, :completed}] = LoopingSubchart.children(store, parent)
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewed_all"]
  end

  # sabotage: in Driver's started_before?/3, spared every later pass's
  # child (answered false for any id under the later-pass shape) -> red,
  # the second skip left the second pass's child :active. Verified red,
  # reverted from a copy.
  test "leaving the state mid-pass cancels that pass's child, the first and a later one alike",
       %{store: store} do
    parent = "execution_loan_renewals_3"
    driver = LoopingSubchart.driver(store, @type_name)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
    assert {:ok, _execution, _machine_state} = Driver.send_event(driver, parent, skip())

    assert [{^first, :cancelled}, {second, :active}] = LoopingSubchart.children(store, parent)

    assert {:ok, _execution, _machine_state} = Driver.send_event(driver, parent, skip())

    assert [{^first, :cancelled}, {^second, :cancelled}, {third, :active}] =
             LoopingSubchart.children(store, parent)

    refute third == second
  end

  # sabotage: in Driver's later_pass/5, refused `:execution_exists` at the
  # later pass's id instead of adopting -> red, the refusal sent the
  # parent to "refused", whose exit cancelled the second pass's child.
  # Verified red, reverted from a copy.
  test "a re-drive of the second pass adopts its child and creates no third", %{store: store} do
    parent = "execution_loan_renewals_2"
    driver = LoopingSubchart.driver(store, @type_name)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
    before_second_pass = LoopingSubchart.record(store, parent)

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)
    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)
    second_record = LoopingSubchart.record(store, second)

    # The parent's persist of the second pass is lost, and the answer that
    # drove it is delivered again: the same step, from the same position.
    :ok = LoopingSubchart.lose_step(store, before_second_pass)

    assert {:ok, _execution, _machine_state} =
             Driver.answer_parent(driver, first, {:done, nil})

    assert [{^first, :completed}, {^second, :active}] = LoopingSubchart.children(store, parent)
    assert LoopingSubchart.record(store, second) == second_record
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewing"]

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, second)
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewed_all"]
  end

  # sabotage: in Driver's current_pass?/4, answered true for every child
  # (the invoke id alone decided, the 0.26.0 rule) -> red, the duplicate
  # was delivered and answer_parent/3 answered {:ok, ...}, not
  # {:discarded, _}. Verified red, reverted from a copy.
  test "a duplicate answer of an earlier pass, after the next pass started, changes nothing", %{
    store: store
  } do
    parent = "execution_loan_renewals_4"
    driver = LoopingSubchart.driver(store, @type_name)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)
    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)
    parent_record = LoopingSubchart.record(store, parent)

    assert {:discarded, _execution} = Driver.answer_parent(driver, first, {:done, nil})

    assert LoopingSubchart.record(store, parent).position_blob == parent_record.position_blob
    assert [{^first, :completed}, {^second, :active}] = LoopingSubchart.children(store, parent)

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, second)
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewed_all"]
  end

  # sabotage: in Driver's current_pass?/4's pass_order/3, kept a later
  # pass's child whatever its macrostep (dropped the `<= macrostep` guard)
  # -> red, the second pass's child's answer was taken as the first pass's
  # and the parent's stored position moved before the re-drive. Verified red,
  # reverted from a copy. And in adopt_later/2, refused an ended child
  # instead of answering from its record -> red, the re-drive's parent
  # landed in "refused". Verified red, reverted from a copy.
  test "a later pass's child that ended before the re-drive answers the pass that adopts it", %{
    store: store
  } do
    parent = "execution_loan_renewals_5"
    driver = LoopingSubchart.driver(store, @type_name)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
    before_second_pass = LoopingSubchart.record(store, parent)

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)
    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)

    # The parent's persist of the second pass is lost, and the child that
    # pass started ends before anything re-drives it: its answer reaches a
    # parent still waiting on the first pass, which is not its pass.
    :ok = LoopingSubchart.lose_step(store, before_second_pass)

    assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, second)

    assert LoopingSubchart.record(store, parent).position_blob ==
             before_second_pass.position_blob

    # The first pass's answer, delivered again, re-drives the second pass,
    # which adopts its ended child and takes that child's recorded answer.
    assert {:ok, _execution, _machine_state} =
             Driver.answer_parent(driver, first, {:done, nil})

    assert [{^first, :completed}, {^second, :completed}] = LoopingSubchart.children(store, parent)
    assert LoopingSubchart.leaves(store, @type_name, parent) == ["renewed_all"]
  end

  defp skip, do: Statifier.Event.external("skip")
end
