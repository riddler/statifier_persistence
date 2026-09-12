defmodule StatifierPersistence.DriverFanoutLiveTest do
  @moduledoc """
  The fan-out settlement (sp-t57) under real concurrency against real
  Postgres (ADR-0005): N children finishing at once, each on its own
  connection, and the assembled answer that has to carry every child's
  donedata whatever order they landed in.

  This is the case sp-kl3 was filed from. It was found live, under an
  Oban queue, and not on the serialized test path, because the serialized
  path never interleaves a child's terminal status write with a sibling's
  settlement read: a child's status is persisted by its own drive and its
  answer by the settlement that follows it, so a settlement judging
  terminality by status alone could assemble a completed child with a nil
  donedata. `DriverFanoutTest` holds that interleaving still and pins it
  deterministically; this test is the one that would have caught it in the
  first place.

  Live, outside the SQL sandbox, for `EctoLiveLockTest`'s own reason: the
  sandbox funnels every caller through one shared connection, which
  serializes the settlements by connection ownership alone and would mask
  exactly the race this exists for. Each task here takes its own pooled
  connection, so the ordering observed is the database's.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.TestRepo

  @adapter Storage.Ecto
  @adapter_opts [persistence: Default]

  # The children per invocation, and how many invocations the test drives.
  # Both are small on purpose: the window this reproduces is one write
  # wide, so the cost of missing it is paid in rounds rather than in
  # children, and six children on six connections against a default pool
  # is a load the CI service container carries.
  @children 6
  @rounds 25

  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <datamodel><data id="item"/></datamodel>
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done">
          <donedata><content expr="item"/></donedata>
      </final>
  </scxml>
  """

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    on_exit(fn ->
      TestRepo.delete_all(Default.Execution)
      TestRepo.delete_all(Default.Position)
      TestRepo.delete_all(Default.Chart)
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(@adapter, @adapter_opts)
    %{store: store}
  end

  # sabotage: in Driver.entry/5, drop the pending-outcome clause (assemble
  # a recorded-nil outcome as an entry again) -> red within the first
  # round, on an assembled list carrying a nil donedata for a child that
  # completed. Verified red, reverted.
  test "N children settling at once assemble every answer", %{store: store} do
    for round <- 1..@rounds do
      parent_execution_id = "execution-fanout-live-#{System.unique_integer([:positive])}-#{round}"
      parent = start_parent(store, parent_execution_id)

      for index <- 0..(@children - 1) do
        assert :ok =
                 Driver.start_child_at(
                   parent,
                   parent_execution_id,
                   effect("item-#{index}"),
                   index,
                   @children
                 )
      end

      tasks =
        for index <- 0..(@children - 1) do
          Task.async(fn -> finish_child(store, parent_execution_id, index) end)
        end

      assert Enum.all?(Task.await_many(tasks, 30_000), &(&1 == :ok))

      assert leaves(reload_parent(store, parent_execution_id)) == ["approved"],
             "round #{round}: the invocation did not settle"

      expected =
        for index <- 0..(@children - 1) do
          %{"index" => index, "status" => "completed", "donedata" => "item-#{index}"}
        end

      assert answered(store, parent_execution_id) == expected,
             "round #{round}: an answer was lost or assembled out of order"
    end
  end

  defp start_parent(store, parent_execution_id) do
    parent = driver(store, @parent_source)
    {:ok, _execution, _machine_state} = Driver.create(parent, parent_execution_id)
    parent
  end

  # Child `index`'s own drive, in its own task and on its own connection:
  # the terminal status and the settlement that follows it, exactly as a
  # queue's worker executions them.
  defp finish_child(store, parent_execution_id, index) do
    child_execution_id = Linkage.child_execution_id(parent_execution_id, "call", index)

    {:ok, _execution, _machine_state} =
      Driver.send_event(child_driver(store), child_execution_id, Event.external("go"))

    :ok
  end

  defp child_driver(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    parent_hash = Machine.identity(parent_machine).content_hash

    resolver = fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end

    driver(store, @child_source, chart_resolver: resolver)
  end

  defp reload_parent(store, parent_execution_id) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)

    {:ok, machine_state} =
      Storage.load_execution_position(store, parent_execution_id, parent_machine)

    machine_state
  end

  defp answered(store, parent_execution_id) do
    store
    |> reload_parent(parent_execution_id)
    |> Map.fetch!(:datamodel)
    |> get_in(["_event", "data"])
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  defp effect(item) do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: %{"item" => item},
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end

  defp driver(store, source, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [
          dispatch: fn _type, _params, _context -> :pending end,
          invoke_types: InvokeTypes.new(types: ["myapp:map"])
        ],
        opts
      )
    )
  end
end
