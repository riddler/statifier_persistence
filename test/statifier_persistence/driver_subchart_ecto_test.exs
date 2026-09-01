defmodule StatifierPersistence.DriverSubchartEctoTest do
  @moduledoc """
  Cascading cancel (sp-nt8 Phase 5, ADR-0008 decision 5) against
  `StatifierPersistence.Storage.Ecto` over real Postgres (ADR-0005) - the
  manual-verification item `driver_subchart_test.exs` cannot cover: that a
  cascade's nested `lock_run/3` calls commit as nested Ecto transactions
  rather than deadlocking. The `{:cancel_invoke, _}` effect fires from
  inside the parent's own `AdapterLock`/`lock_run/3` transaction (its
  advisory lock already held), and the cascade's own `cancel/3` calls for
  the child and then the grandchild each open a `lock_run/3` transaction of
  their own underneath it, parent-first every time by construction (the
  walk cancels a run before it ever queries for that run's own children).

  `async: false`, the demo variant's own reason
  (`StatifierPersistence.Demo.RestartDemoEctoTest`): one sandbox-checked-out
  connection drives every `Storage.new/2` handle in a test.
  """

  use ExUnit.Case, async: false

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Run.Linkage

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
  # sabotage: cancel_and_descend/3 (runs.ex) short-circuited to skip the
  # recursive cascade_cancel/3 call -> red, the grandchild stayed :active
  # instead of :cancelled. Verified red against Postgres, reverted.
  test "a three-deep cascade commits under nested Ecto lock_run/3 transactions", %{store: store} do
    driver = driver(store, @parent_source, nesting_dispatch())

    assert {:ok, _run, _ms} = Driver.create(driver, "run_ecto_1")

    child_run_id = Linkage.child_run_id("run_ecto_1", "call", 0)
    grandchild_run_id = Linkage.child_run_id(child_run_id, "nested", 0)

    assert {:ok, before_child} = Storage.fetch_run(store, child_run_id)
    assert {:ok, before_grandchild} = Storage.fetch_run(store, grandchild_run_id)
    assert before_child.status == :active
    assert before_grandchild.status == :active

    assert {:ok, _run, machine_state} =
             Driver.send_event(driver, "run_ecto_1", Event.external("timeout"))

    assert leaves(machine_state) == ["abandoned"]

    assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
    assert {:ok, grandchild_record} = Storage.fetch_run(store, grandchild_run_id)
    assert child_record.status == :cancelled
    assert grandchild_record.status == :cancelled
    assert child_record.position_blob == before_child.position_blob
    assert grandchild_record.position_blob == before_grandchild.position_blob
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

  defp driver(store, source, dispatch) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(store, machine,
      dispatch: dispatch,
      invoke_types: InvokeTypes.new(types: ["myapp:subchart"])
    )
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
