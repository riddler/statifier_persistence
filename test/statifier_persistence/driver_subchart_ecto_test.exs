defmodule StatifierPersistence.DriverSubchartEctoTest do
  @moduledoc """
  Cascading cancel (sp-nt8 Phase 5, ADR-0008 decision 5) against
  `StatifierPersistence.Storage.Ecto` over real Postgres (ADR-0005) - the
  manual-verification item `driver_subchart_test.exs` cannot cover: that a
  cascade's nested `lock_execution/3` calls commit as nested Ecto transactions
  rather than deadlocking. The `{:cancel_invoke, _}` effect fires from
  inside the parent's own `AdapterLock`/`lock_execution/3` transaction (its
  advisory lock already held), and the cascade's own `cancel/3` calls for
  the child and then the grandchild each open a `lock_execution/3` transaction of
  their own underneath it, parent-first every time by construction (the
  walk cancels an execution before it ever queries for that execution's own children).

  `async: false`, the demo variant's own reason
  (`StatifierPersistence.Demo.RestartDemoEctoTest`): one sandbox-checked-out
  connection drives every `Storage.new/2` handle in a test.
  """

  use ExUnit.Case, async: false

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Executions, Storage}
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Test.LoopingSubchart

  @adapter Storage.Ecto
  @adapter_opts [persistence: EctoHosts.Default, sandbox: true]

  # The same three-level shape as `DriverSubchartTest`'s nesting fixture:
  # a parent invoking "call", whose child itself invokes "nested", whose
  # own child is a plain leaf - and a "timeout" way out of the invoking
  # state that cascades the cancel.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="abandoned"/>
  </scxml>
  """

  @nesting_child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="nested" type="myapp:subchart"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="abandoned"/>
  </scxml>
  """

  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle"/>
  </scxml>
  """

  # sp-y7n's parent: the same one invocation, with the failing door's
  # transition on it so an answer has somewhere to land.
  @answering_parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(@adapter, @adapter_opts)
    :ok = @adapter.isolate(store.opts)
    %{store: store}
  end

  # Manual verification (sp-nt8 Phase 5): run this against Postgres, not
  # only the in-memory Agent, and confirm no lock timeout and no
  # `deadlock detected` - a plain pass is the confirmation, the same way
  # the demo's own Ecto variant confirms its default `AdapterLock`
  # serialization by running to completion.
  # sabotage: cancel_and_descend/3 (executions.ex) short-circuited to skip the
  # recursive cascade_cancel/3 call -> red, the grandchild stayed :active
  # instead of :cancelled. Verified red against Postgres, reverted.
  test "a three-deep cascade commits under nested Ecto lock_execution/3 transactions", %{
    store: store
  } do
    driver = driver(store, @parent_source, nesting_dispatch())

    assert {:ok, _execution, _ms} = Driver.create(driver, "execution_ecto_1")

    child_execution_id = Linkage.child_execution_id("execution_ecto_1", "call", 0)
    grandchild_execution_id = Linkage.child_execution_id(child_execution_id, "nested", 0)

    assert {:ok, before_child} = Storage.fetch_execution(store, child_execution_id)
    assert {:ok, before_grandchild} = Storage.fetch_execution(store, grandchild_execution_id)
    assert before_child.status == :active
    assert before_grandchild.status == :active

    assert {:ok, _execution, machine_state} =
             Driver.send_event(driver, "execution_ecto_1", Event.external("timeout"))

    assert leaves(machine_state) == ["abandoned"]

    assert {:ok, child_record} = Storage.fetch_execution(store, child_execution_id)
    assert {:ok, grandchild_record} = Storage.fetch_execution(store, grandchild_execution_id)
    assert child_record.status == :cancelled
    assert grandchild_record.status == :cancelled
    assert child_record.position_blob == before_child.position_blob
    assert grandchild_record.position_blob == before_grandchild.position_blob
  end

  # sp-y7n (ruled by the operator, 2026-09-06), the Postgres half of the
  # pair whose SQLite half is `StatifierPersistence.Ecto.SqliteMigrationsTest`:
  # a linked child failed
  # from outside the interpreter through `Executions.fail/4` answers its parent.
  # What this backend adds over the in-memory case in
  # `StatifierPersistence.DriverSubchartTest` is the one thing that could
  # only fail here - the child's status write commits under its own
  # `lock_execution/3` transaction and the parent's answer opens a second one
  # after it, sequentially rather than nested, so a real advisory lock has
  # no deadlock to find.
  #
  # sabotage: in `Executions.answer_parent_of_failed/4`, replaced the `driver`
  # clause's `Driver.resolve_and_answer_parent/3` call with a bare
  # `result` -> red against Postgres, with the parent still in "calling"
  # and its `_event` never written. Verified red, reverted.
  test "an outside fail on a linked child answers the parent, each lock in turn", %{store: store} do
    {:ok, parent_machine} = Statifier.compile(@answering_parent_source)

    driver =
      driver(store, @answering_parent_source, subchart_dispatch(@child_source),
        chart_resolver: parent_resolver(parent_machine)
      )

    assert {:ok, _execution, _ms} = Driver.create(driver, "execution_ecto_fail_1")

    child_execution_id = Linkage.child_execution_id("execution_ecto_fail_1", "call", 0)

    assert {:ok, child_execution} =
             Executions.fail(store, child_execution_id, "boom", driver: driver)

    assert child_execution.status == :failed

    assert {:ok, child_record} = Storage.fetch_execution(store, child_execution_id)
    assert child_record.status == :failed
    assert child_record.failure == "boom"

    assert {:ok, parent_reloaded} =
             Storage.load_execution_position(store, "execution_ecto_fail_1", parent_machine)

    assert leaves(parent_reloaded) == ["refused"]
    assert parent_reloaded.datamodel["_event"]["data"]["reason"] == "boom"
  end

  # The crash window ADR-0004 decision 3 names, on Postgres: the child an
  # interrupted drive created is already there when the parent's create
  # re-drives, inside the parent's own lock transaction.
  # sabotage: in Driver's single-child create_child/6, called
  # create_or_adopt/5 at the first id without the read before it (the
  # 0.26.0 create-then-adopt order) -> red against Postgres, the refused
  # insert aborted the lock transaction and the adoption read raised
  # in_failed_sql_transaction. Verified red, reverted from a copy.
  test "a re-drive that finds its single child already created adopts it", %{store: store} do
    driver = driver(store, @parent_source, subchart_dispatch(@child_source))
    child_execution_id = Linkage.child_execution_id("execution_ecto_redrive", "call", 0)

    {:ok, child_machine} = Statifier.compile(@child_source)
    content_hash = Machine.identity(child_machine).content_hash
    linkage = Linkage.new("execution_ecto_redrive", "call", 0, content_hash)

    assert {:ok, _execution, _ms} =
             Executions.create(store, child_execution_id, child_machine,
               executor: fn _effect, _context -> :ok end,
               linkage: linkage
             )

    assert {:ok, pre_redrive} = Storage.fetch_execution(store, child_execution_id)

    assert {:ok, _execution, machine_state} = Driver.create(driver, "execution_ecto_redrive")

    assert Map.values(machine_state.active_invocations) == ["call"]
    assert {:ok, ^pre_redrive} = Storage.fetch_execution(store, child_execution_id)
  end

  # ADR-0008's 2026-11-22 Amendment on Postgres: the in-memory drive in
  # `DriverSubchartLoopTest`, here under `AdapterLock`, so each later
  # pass's child is created inside the parent's own lock transaction.
  # sabotage: in Driver's first_child/2, adopted a child at the first id
  # whatever its status (the 0.26.0 rule) -> red against Postgres, one
  # child listed where two were asserted. Verified red, reverted from a copy.
  test "two passes of a loop start two children in order and the parent goes on", %{
    store: store
  } do
    parent = "execution_ecto_renewals_1"
    driver = LoopingSubchart.driver(store, "myapp:subchart")
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _ms} = Driver.create(driver, parent)
    assert LoopingSubchart.children(store, parent) == [{first, :active}]

    assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(driver, first)
    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)
    assert String.starts_with?(second, first <> "@")

    assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(driver, second)
    assert LoopingSubchart.leaves(store, "myapp:subchart", parent) == ["renewed_all"]
  end

  # The stored state a lost persist leaves where the child's create and
  # the parent's step commit apart, built here by putting the parent's
  # record back: on Postgres under `AdapterLock` a lost drive cannot leave
  # it (`LoopLostDriveTest`), so this pins the re-drive's code path under
  # real lock transactions rather than a state this store reaches.
  # sabotage: in Driver's started_before?/3, answered true for every child
  # (the cancel reached every pass) -> red against Postgres, the re-drive's
  # own exit cancelled the second pass's child before its invoke adopted
  # it. Verified red, reverted from a copy.
  test "a re-drive of a loop's second pass adopts its child", %{store: store} do
    parent = "execution_ecto_renewals_2"
    driver = LoopingSubchart.driver(store, "myapp:subchart")
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _ms} = Driver.create(driver, parent)
    before_second_pass = LoopingSubchart.record(store, parent)

    assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))
    assert [{^first, :cancelled}, {second, :active}] = LoopingSubchart.children(store, parent)

    :ok = LoopingSubchart.lose_step(store, before_second_pass)
    assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))

    assert [{^first, :cancelled}, {^second, :active}] = LoopingSubchart.children(store, parent)
    assert LoopingSubchart.leaves(store, "myapp:subchart", parent) == ["renewing"]
  end

  # sabotage: in Driver's current_pass?/3, answered true for every child
  # -> red against Postgres, the duplicate was delivered and
  # answer_parent/3 answered {:ok, ...}, not {:discarded, _}. Verified red,
  # reverted from a copy.
  test "a duplicate answer of a loop's earlier pass changes nothing", %{store: store} do
    parent = "execution_ecto_renewals_3"
    driver = LoopingSubchart.driver(store, "myapp:subchart")
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _ms} = Driver.create(driver, parent)
    assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(driver, first)
    assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)

    assert {:discarded, _execution} = Driver.answer_parent(driver, first, {:done, nil})
    assert [{^first, :completed}, {^second, :active}] = LoopingSubchart.children(store, parent)
    assert LoopingSubchart.leaves(store, "myapp:subchart", parent) == ["renewing"]
  end

  # The same built state, and the second pass's child ends first with its
  # answer kept on its record but never taken (its parent's chart did not
  # resolve); the re-drive's buffered answer runs inside the lock.
  # sabotage: in Driver's adopt_later/2, refused an ended child instead of
  # answering from its record -> red against Postgres, the parent landed in
  # "refused". Verified red, reverted from a copy.
  test "a loop's later-pass child that ended before the re-drive answers its pass", %{
    store: store
  } do
    parent = "execution_ecto_renewals_4"
    driver = LoopingSubchart.driver(store, "myapp:subchart")

    unresolving =
      LoopingSubchart.driver(store, "myapp:subchart", chart_resolver: fn _hash -> :error end)

    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

    assert {:ok, _execution, _ms} = Driver.create(driver, parent)
    before_second_pass = LoopingSubchart.record(store, parent)

    assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))
    assert [{^first, :cancelled}, {second, :active}] = LoopingSubchart.children(store, parent)

    :ok = LoopingSubchart.lose_step(store, before_second_pass)
    assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(unresolving, second)
    assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))

    assert [{^first, :cancelled}, {^second, :completed}, {_third, :active}] =
             LoopingSubchart.children(store, parent)
  end

  defp nesting_dispatch do
    fn "myapp:subchart", _params, %{invoke_id: invoke_id} ->
      content = if invoke_id == "call", do: @nesting_child_source, else: @child_source

      invoke = %Statifier.Effect.Invoke{
        invoke_id: invoke_id,
        type: "myapp:subchart",
        src: nil,
        params: nil,
        content: content,
        autoforward: nil,
        state_index: 0,
        invoke_index: 0,
        macrostep: 0,
        microstep: 0,
        round: 0
      }

      {:start_child, invoke, {:invoke, invoke}}
    end
  end

  defp driver(store, source, dispatch, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [dispatch: dispatch, invoke_types: InvokeTypes.new(types: ["myapp:subchart"])],
        opts
      )
    )
  end

  defp subchart_dispatch(content) do
    fn "myapp:subchart", _params, %{invoke_id: invoke_id} ->
      invoke = %Statifier.Effect.Invoke{
        invoke_id: invoke_id,
        type: "myapp:subchart",
        src: nil,
        params: nil,
        content: content,
        autoforward: nil,
        state_index: 0,
        invoke_index: 0,
        macrostep: 0,
        microstep: 0,
        round: 0
      }

      {:start_child, invoke, {:invoke, invoke}}
    end
  end

  defp parent_resolver(parent_machine) do
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
