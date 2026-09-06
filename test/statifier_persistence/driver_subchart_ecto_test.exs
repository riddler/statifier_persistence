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
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Runs, Storage}
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

  # sp-y7n / RQ-SF035-9, the Postgres half of the pair whose SQLite half is
  # `StatifierPersistence.Ecto.SqliteMigrationsTest`: a linked child failed
  # from outside the interpreter through `Runs.fail/4` answers its parent.
  # What this backend adds over the in-memory case in
  # `StatifierPersistence.DriverSubchartTest` is the one thing that could
  # only fail here - the child's status write commits under its own
  # `lock_run/3` transaction and the parent's answer opens a second one
  # after it, sequentially rather than nested, so a real advisory lock has
  # no deadlock to find.
  #
  # sabotage: in `Runs.answer_parent_of_failed/4`, replaced the `driver`
  # clause's `Driver.resolve_and_answer_parent/3` call with a bare
  # `result` -> red against Postgres, with the parent still in "calling"
  # and its `_event` never written. Verified red, reverted.
  test "an outside fail on a linked child answers the parent, each lock in turn", %{store: store} do
    {:ok, parent_machine} = Statifier.compile(@answering_parent_source)

    driver =
      driver(store, @answering_parent_source, subchart_dispatch(@child_source),
        chart_resolver: parent_resolver(parent_machine)
      )

    assert {:ok, _run, _ms} = Driver.create(driver, "run_ecto_fail_1")

    child_run_id = Linkage.child_run_id("run_ecto_fail_1", "call", 0)

    assert {:ok, child_run} = Runs.fail(store, child_run_id, "boom", driver: driver)
    assert child_run.status == :failed

    assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
    assert child_record.status == :failed
    assert child_record.failure == "boom"

    assert {:ok, parent_reloaded} =
             Storage.load_run_position(store, "run_ecto_fail_1", parent_machine)

    assert leaves(parent_reloaded) == ["refused"]
    assert parent_reloaded.datamodel["_event"]["data"]["reason"] == "boom"
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
