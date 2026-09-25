defmodule StatifierPersistence.DriverSingleChildAnswerTest do
  @moduledoc """
  A single durable child's answer is recorded on its own execution record,
  so an answer its parent refused, or never received, is read back from
  that record and delivered again through `Driver.answer_parent/3`
  (ADR-0008's 2026-09-24 Amendment), over both shipped adapters.

  The parent is parked the way a migration parks one: its status alone
  written through `StatifierPersistence.Storage.update_execution_status/4`.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias Statifier.MachineState
  alias StatifierPersistence.{Driver, EctoHosts, Execution, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage

  @parent_source """
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

  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done">
          <donedata><content expr="'child-result'"/></donedata>
      </final>
  </scxml>
  """

  setup %{adapter: adapter} do
    store = store(adapter)
    {:ok, parent} = Statifier.compile(@parent_source)
    {:ok, child} = Statifier.compile(@child_source)
    child_id = Linkage.child_execution_id("parent-1", "call", 0)

    %{store: store, parent: parent, child: child, child_id: child_id}
  end

  describe "a single child's answer" do
    # sabotage: dropped the record_single_answer/3 call from answer_parent/3's
    # single-child branch -> red over both adapters, the child's record read
    # back donedata: nil and its outcome_blob was nil. Reverted from a copy.
    test "a parked parent refused is recorded on the child and delivered again from it", %{
      store: store,
      parent: parent,
      child: child,
      child_id: child_id
    } do
      driver = driver(store, parent, resolver([parent, child]))
      {:ok, _execution, _ms} = Driver.create(driver, "parent-1")
      :ok = Storage.update_execution_status(store, "parent-1", :needs_migration)

      assert {:ok, %Execution{status: :completed}, _ms} =
               Driver.send_event(%{driver | machine: child}, child_id, Event.external("go"))

      assert {:ok, %{status: :needs_migration}} = Storage.fetch_execution(store, "parent-1")

      # The host holds nothing: it reads the answer back from the child.
      assert {:ok, record} = Storage.fetch_execution(store, child_id)
      assert {:done, "child-result"} = :erlang.binary_to_term(record.outcome_blob)
      assert %Execution{status: :completed, donedata: donedata} = Execution.from_record(record)
      assert donedata == "child-result"

      assert {:ok, %Execution{status: :active}} = Executions.unpark(store, "parent-1")

      assert {:ok, %Execution{execution_id: "parent-1"}, parent_ms} =
               Driver.answer_parent(driver, child_id, {:done, donedata})

      assert leaves(parent_ms) == ["approved"]
      assert parent_ms.datamodel["_event"]["data"] == "child-result"
    end

    # sabotage: dropped the record_single_answer/3 call from unreached/5's
    # single-child clause -> red over both adapters, outcome_blob stayed nil.
    # Reverted from a copy.
    test "is recorded when the parent's chart does not resolve", %{
      store: store,
      parent: parent,
      child: child,
      child_id: child_id
    } do
      driver = driver(store, parent, resolver([child]))
      {:ok, _execution, _ms} = Driver.create(driver, "parent-1")

      assert {:ok, %Execution{status: :completed}, _ms} =
               Driver.send_event(%{driver | machine: child}, child_id, Event.external("go"))

      assert {:ok, record} = Storage.fetch_execution(store, child_id)
      assert Execution.from_record(record).donedata == "child-result"
    end

    # sabotage: made answer_names?/2's {:failed, _} clause answer false ->
    # red over both adapters, the failed child recorded nothing. Reverted
    # from a copy.
    test "of a failed child is recorded, and its failure answers the parent again", %{
      store: store,
      parent: parent,
      child: child,
      child_id: child_id
    } do
      driver = driver(store, parent, resolver([parent, child]))
      {:ok, _execution, _ms} = Driver.create(driver, "parent-1")
      :ok = Storage.update_execution_status(store, "parent-1", :needs_migration)

      assert {:ok, %Execution{status: :failed}} =
               Executions.fail(store, child_id, "boom", driver: driver)

      assert {:ok, record} = Storage.fetch_execution(store, child_id)
      assert {:failed, [reason: "boom"]} = :erlang.binary_to_term(record.outcome_blob)

      assert %Execution{status: :failed, failure: "boom", donedata: nil} =
               execution = Execution.from_record(record)

      assert {:ok, %Execution{status: :active}} = Executions.unpark(store, "parent-1")

      assert {:ok, _parent, parent_ms} =
               Driver.answer_parent(driver, child_id, {:failed, reason: execution.failure})

      assert leaves(parent_ms) == ["refused"]
    end

    # sabotage: dropped the outcome_blob: nil match from
    # record_single_answer/3's fetch -> red over both adapters, the second
    # answer overwrote the recorded one. Reverted from a copy.
    test "is recorded once: a later answer rewrites nothing", %{
      store: store,
      parent: parent,
      child: child,
      child_id: child_id
    } do
      driver = driver(store, parent, resolver([parent, child]))
      {:ok, _execution, _ms} = Driver.create(driver, "parent-1")

      {:ok, _execution, _ms} =
        Driver.send_event(%{driver | machine: child}, child_id, Event.external("go"))

      assert {:discarded, _parent} = Driver.answer_parent(driver, child_id, {:done, "other"})

      assert {:ok, record} = Storage.fetch_execution(store, child_id)
      assert Execution.from_record(record).donedata == "child-result"
    end

    # sabotage: made answer_names?/2's {:done, _} clause answer true for any
    # status -> red over both adapters, the active child's record gained an
    # answer. Reverted from a copy.
    test "handed over for a child that is not terminal records nothing", %{
      store: store,
      parent: parent,
      child: child,
      child_id: child_id
    } do
      driver = driver(store, parent, resolver([parent, child]))
      {:ok, _execution, _ms} = Driver.create(driver, "parent-1")

      assert {:ok, _parent, parent_ms} = Driver.answer_parent(driver, child_id, {:done, "early"})

      # The parent took the answer and left the invoking state, which
      # cancels the child; the child was :active when the answer came, so
      # nothing was recorded on it.
      assert leaves(parent_ms) == ["approved"]

      assert {:ok, %{status: :cancelled, outcome_blob: nil}} =
               Storage.fetch_execution(store, child_id)
    end
  end

  describe "Execution.from_record/1" do
    # sabotage: made from_record/1 set donedata: nil again -> red over both
    # adapters at the first donedata assertion. Reverted from a copy.
    test "reads donedata from a recorded answer, and nil for a failure or no answer", %{
      store: store,
      child: child
    } do
      {:ok, _execution, _ms} = Executions.create(store, "plain-1", child, executor: &quiet/2)
      {:ok, before} = Storage.fetch_execution(store, "plain-1")

      :ok =
        Storage.update_execution_status(store, "plain-1", :completed,
          outcome_blob: :erlang.term_to_binary({:done, %{"total" => 3}})
        )

      {:ok, answered} = Storage.fetch_execution(store, "plain-1")

      # A record with no recorded answer: an execution that is not a child,
      # or a child that ended before its answer was recorded.
      assert Execution.from_record(before).donedata == nil
      assert Execution.from_record(answered).donedata == %{"total" => 3}

      failed = %{answered | outcome_blob: :erlang.term_to_binary({:failed, reason: "x"})}
      assert Execution.from_record(failed).donedata == nil
    end
  end

  defp store(:in_memory) do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    store
  end

  defp store(:ecto) do
    {:ok, store} =
      Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)

    :ok = Storage.Ecto.isolate(store.opts)
    store
  end

  defp quiet(_effect, _context), do: :ok

  defp driver(store, parent, resolver) do
    child_source = @child_source

    dispatch = fn "myapp:subchart", _params, %{invoke: invoke} ->
      resolved = %{invoke | content: child_source}
      {:start_child, resolved, {:invoke, resolved}}
    end

    Driver.new(store, parent,
      dispatch: dispatch,
      invoke_types: InvokeTypes.new(types: ["myapp:subchart"]),
      chart_resolver: resolver
    )
  end

  # Resolves exactly the machines it is given, and nothing else.
  defp resolver(machines) do
    charts = Map.new(machines, &{Machine.identity(&1).content_hash, &1})
    fn content_hash -> Map.fetch(charts, content_hash) end
  end

  defp leaves(machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
