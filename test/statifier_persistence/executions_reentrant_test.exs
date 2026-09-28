defmodule StatifierPersistence.ExecutionsReentrantTest do
  @moduledoc false
  # ADR-0004's 2026-09-26 Amendment: while an execution's executor runs,
  # every public door of StatifierPersistence.Executions that takes an
  # execution id refuses that execution with {:error, {:reentrant_step, id}}
  # from the calling process, before it reads or writes anything, and the
  # outer step's position is the one stored.
  #
  # The outer step takes the in-memory adapter's own lock. Each nested door
  # is handed a serialization strategy that admits its own holder, the
  # shape of the Ecto adapter's transaction-scoped advisory lock, so that a
  # missing refusal shows up as the lost update the Amendment names rather
  # than as the in-memory lock spinning on itself.
  use ExUnit.Case, async: true

  alias Statifier.{Event, Machine, MachineState}
  alias StatifierPersistence.{Execution, Executions, Storage}
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.Storage.InMemory

  defmodule ReentrantSerialization do
    @moduledoc false
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(_config, _execution_id, fun), do: {:ok, fun.()}
  end

  # "go" leaves `a` for `b` and hands the executor one <log>, which is where
  # each test's executor calls back in. "other" would take a nested step to
  # `x`, so a stored `x` is a nested write and a stored `b` is the outer one.
  @chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"><log label="reenter"/></transition>
          <transition event="other" target="x"/>
      </state>
      <state id="b"/>
      <state id="x"/>
  </scxml>
  """

  # The same chart with an onentry <log> on the initial state, so a create
  # hands the executor an effect too.
  @create_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry><log label="created"/></onentry>
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @nested [serialization: {ReentrantSerialization, nil}]

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    {:ok, machine} = Statifier.compile(@chart_source)
    %{store: store, machine: machine}
  end

  defp quiet(_effect, _context), do: :ok

  defp create!(store, execution_id, machine) do
    {:ok, _execution, _machine_state} =
      Executions.create(store, execution_id, machine, executor: &quiet/2)

    :ok
  end

  # Steps `execution_id` with "go", calling `door` with the execution id from
  # inside the executor and sending its answer back to the test process.
  defp step_reentering(store, execution_id, machine, door) do
    test_pid = self()

    executor = fn _effect, %{execution_id: id} ->
      send(test_pid, {:nested, door.(id)})
      :ok
    end

    Executions.step(store, execution_id, machine, Event.external("go"), executor: executor)
  end

  defp leaves(store, execution_id, machine) do
    {:ok, machine_state} = Storage.load_execution_position(store, execution_id, machine)

    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.sort()
  end

  defp stored_status(store, execution_id) do
    {:ok, %{status: status}} = Storage.fetch_execution(store, execution_id)
    status
  end

  defp content_hash(%Machine{} = machine), do: Machine.identity(machine).content_hash

  # Asserts the whole outcome every door's test shares: the outer step
  # returned normally, the nested door answered the refusal for this id,
  # and the outer step's `b` is what is stored, still `:active`.
  defp assert_refused_and_stored(result, store, execution_id, machine) do
    assert {:ok, %Execution{status: :active}, _machine_state} = result
    assert_received {:nested, {:error, {:reentrant_step, ^execution_id}}}
    assert leaves(store, execution_id, machine) == ["b"]
    assert stored_status(store, execution_id) == :active
  end

  describe "a door called for the execution whose executor is running" do
    # sabotage: in Executions.create/4, call create_open/4 without the
    # not_in_step/1 check -> red, the nested create answered
    # {:error, :execution_exists} rather than the refusal (the outer one's
    # row was already there), so the refusal assertion failed. Verified red,
    # reverted from a copy.
    test "create/4 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-create", machine)

      result =
        step_reentering(store, "reentrant-create", machine, fn id ->
          Executions.create(store, id, machine, [executor: &quiet/2] ++ @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-create", machine)
    end

    # sabotage: in Executions.step/5, drop the not_in_step/1 check -> red,
    # the nested step answered {:ok, %Execution{status: :active}, _} where
    # the refusal was asserted. Verified red, reverted from a copy.
    test "step/5 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-step", machine)

      result =
        step_reentering(store, "reentrant-step", machine, fn id ->
          Executions.step(
            store,
            id,
            machine,
            Event.external("other"),
            [executor: &quiet/2] ++ @nested
          )
        end)

      assert_refused_and_stored(result, store, "reentrant-step", machine)
    end

    # sabotage: in Executions.fail/4, drop the not_in_step/1 check -> red,
    # the nested fail answered {:ok, %Execution{status: :failed}} where the
    # refusal was asserted. Verified red, reverted from a copy.
    test "fail/4 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-fail", machine)

      result =
        step_reentering(store, "reentrant-fail", machine, fn id ->
          Executions.fail(store, id, "from inside", @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-fail", machine)
    end

    # sabotage: in Executions.cancel/3, drop the not_in_step/1 check -> red,
    # the nested cancel answered {:ok, %Execution{status: :cancelled}} where
    # the refusal was asserted. Verified red, reverted from a copy.
    test "cancel/3 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-cancel", machine)

      result =
        step_reentering(store, "reentrant-cancel", machine, fn id ->
          Executions.cancel(store, id, @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-cancel", machine)
    end

    # sabotage: in Executions.unpark/3, drop the not_in_step/1 check -> red,
    # the nested unpark read the :active record and answered
    # {:ok, %Execution{status: :active}} instead of the refusal. Verified
    # red, reverted from a copy.
    test "unpark/3 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-unpark", machine)

      result =
        step_reentering(store, "reentrant-unpark", machine, fn id ->
          Executions.unpark(store, id, @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-unpark", machine)
    end

    # sabotage: in Executions.migrate/4, call migrate_open/4 without the
    # not_in_step/1 check -> red, the nested migrate moved the execution
    # and answered {:ok, %Execution{}, _facts}. Verified red, reverted from
    # a copy.
    test "migrate/4 refuses", %{store: store, machine: machine} do
      {:ok, to_machine} = Statifier.compile(@create_chart_source)
      create!(store, "reentrant-migrate", machine)
      {:ok, plan} = Plan.new(from: content_hash(machine), to: content_hash(to_machine))

      result =
        step_reentering(store, "reentrant-migrate", machine, fn id ->
          Executions.migrate(
            store,
            id,
            plan,
            [from_machine: machine, to_machine: to_machine] ++ @nested
          )
        end)

      assert_refused_and_stored(result, store, "reentrant-migrate", machine)
    end

    # sabotage: in Executions.migrate_tree/4, call migrate_tree_open/4
    # without the not_in_step/1 check -> red, the nested call moved the
    # tree and answered {:ok, [_ | _]}; the next case went red under the
    # same mutation. Verified red, reverted from a copy.
    test "migrate_tree/4 refuses when the root is the execution", %{
      store: store,
      machine: machine
    } do
      {:ok, to_machine} = Statifier.compile(@create_chart_source)
      create!(store, "reentrant-tree", machine)
      {:ok, plan} = Plan.new(from: content_hash(machine), to: content_hash(to_machine))

      machines = %{content_hash(machine) => machine, content_hash(to_machine) => to_machine}

      result =
        step_reentering(store, "reentrant-tree", machine, fn id ->
          Executions.migrate_tree(store, id, %{id => plan}, [machines: machines] ++ @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-tree", machine)
    end

    # sabotage: in Executions.migrate_tree/4, check only the root id
    # (not_in_step(root_execution_id)) -> red, the nested call read the
    # other root's tree and answered {:error, {:tree_refused, _}} instead of
    # the refusal. Verified red, reverted from a copy.
    test "migrate_tree/4 refuses when its plans name the execution under another root", %{
      store: store,
      machine: machine
    } do
      {:ok, to_machine} = Statifier.compile(@create_chart_source)
      create!(store, "reentrant-tree-named", machine)
      create!(store, "reentrant-tree-root", machine)
      {:ok, plan} = Plan.new(from: content_hash(machine), to: content_hash(to_machine))

      result =
        step_reentering(store, "reentrant-tree-named", machine, fn id ->
          Executions.migrate_tree(store, "reentrant-tree-root", %{id => plan}, @nested)
        end)

      assert_refused_and_stored(result, store, "reentrant-tree-named", machine)
      assert leaves(store, "reentrant-tree-root", machine) == ["a"]
    end

    # sabotage: in Executions.inputs/2, drop the not_in_step/1 check -> red,
    # the nested read answered the adapter's :not_supported instead of the
    # refusal. Verified red, reverted from a copy.
    test "inputs/2 refuses", %{store: store, machine: machine} do
      create!(store, "reentrant-inputs", machine)

      result =
        step_reentering(store, "reentrant-inputs", machine, fn id ->
          Executions.inputs(store, id)
        end)

      assert_refused_and_stored(result, store, "reentrant-inputs", machine)
    end

    # sabotage: in execute_one/4, call Executor.run/3 without in_step/2 ->
    # red here and in every case above: the create's executor saw no mark,
    # the nested create inserted the row first, and the outer create
    # answered {:error, :execution_exists}. Verified red, reverted from a
    # copy.
    test "a create's own executor is marked too", %{store: store} do
      {:ok, machine} = Statifier.compile(@create_chart_source)
      test_pid = self()

      executor = fn _effect, %{execution_id: id} ->
        nested = Executions.create(store, id, machine, [executor: &quiet/2] ++ @nested)
        send(test_pid, {:nested, nested})
        :ok
      end

      assert {:ok, %Execution{status: :active}, _machine_state} =
               Executions.create(store, "reentrant-at-create", machine, executor: executor)

      assert_received {:nested, {:error, {:reentrant_step, "reentrant-at-create"}}}
      assert leaves(store, "reentrant-at-create", machine) == ["a"]
    end
  end

  describe "an event builder handed to step/5" do
    # Steps `execution_id` with a builder that calls `door` with the
    # execution id from inside the builder, sends its answer back to the
    # test process, and then builds "go".
    defp step_building(store, execution_id, machine, door) do
      test_pid = self()

      builder = fn _machine_state ->
        send(test_pid, {:nested, door.(execution_id)})
        {:ok, Event.external("go")}
      end

      Executions.step(store, execution_id, machine, builder, executor: &quiet/2)
    end

    # sabotage: in step_loaded/8, call resolve_event/2 without in_step/2 ->
    # red, the nested step answered {:ok, %Execution{status: :active}, _}
    # where the refusal was asserted. Verified red, reverted from a copy.
    test "a builder calling a door for its own execution is refused", %{
      store: store,
      machine: machine
    } do
      create!(store, "reentrant-builder", machine)

      result =
        step_building(store, "reentrant-builder", machine, fn id ->
          Executions.step(
            store,
            id,
            machine,
            Event.external("other"),
            [executor: &quiet/2] ++ @nested
          )
        end)

      assert_refused_and_stored(result, store, "reentrant-builder", machine)
    end

    # sabotage: make not_in_step/1 refuse whenever anything is marked
    # (ignore the ids) -> red, the builder's mark refused the step of the
    # other execution. Verified red, reverted from a copy.
    test "a builder calling a door for a different execution proceeds", %{
      store: store,
      machine: machine
    } do
      create!(store, "reentrant-builder-outer", machine)
      create!(store, "reentrant-builder-other", machine)

      result =
        step_building(store, "reentrant-builder-outer", machine, fn _id ->
          Executions.step(
            store,
            "reentrant-builder-other",
            machine,
            Event.external("other"),
            executor: &quiet/2
          )
        end)

      assert {:ok, %Execution{status: :active}, _machine_state} = result
      assert_received {:nested, {:ok, %Execution{status: :active}, _other_state}}
      assert leaves(store, "reentrant-builder-outer", machine) == ["b"]
      assert leaves(store, "reentrant-builder-other", machine) == ["x"]
    end
  end

  describe "what the refusal leaves alone" do
    # sabotage: make not_in_step/1 refuse whenever anything is marked
    # (ignore the ids) -> red, the step of the other execution answered
    # the refusal. Verified red, reverted from a copy.
    test "a door called for a different execution id proceeds", %{
      store: store,
      machine: machine
    } do
      create!(store, "reentrant-outer", machine)
      create!(store, "reentrant-other", machine)

      result =
        step_reentering(store, "reentrant-outer", machine, fn _id ->
          Executions.step(
            store,
            "reentrant-other",
            machine,
            Event.external("other"),
            executor: &quiet/2
          )
        end)

      assert {:ok, %Execution{status: :active}, _machine_state} = result
      assert_received {:nested, {:ok, %Execution{status: :active}, _other_state}}
      assert leaves(store, "reentrant-outer", machine) == ["b"]
      assert leaves(store, "reentrant-other", machine) == ["x"]
    end

    # sabotage: in in_step/2, restore the mark only on a normal return (drop
    # the after block, put the outer list back after fun.()) -> red, the
    # raise left the mark behind and the next step/5 in the loop answered
    # {:error, {:reentrant_step, _}} instead of reaching its executor.
    # Verified red, reverted from a copy.
    test "the mark is cleared when the executor raises, throws or exits", %{
      store: store,
      machine: machine
    } do
      create!(store, "reentrant-raise", machine)

      for leave <- [
            fn -> raise "executor boom" end,
            fn -> throw(:executor_throw) end,
            fn -> exit(:executor_exit) end
          ] do
        executor = fn _effect, _context -> leave.() end

        caught =
          try do
            Executions.step(
              store,
              "reentrant-raise",
              machine,
              Event.external("go"),
              executor: executor
            )
          catch
            kind, _reason -> kind
          end

        assert caught in [:error, :throw, :exit]
      end

      assert leaves(store, "reentrant-raise", machine) == ["a"]

      assert {:ok, %Execution{status: :active}, _machine_state} =
               Executions.step(
                 store,
                 "reentrant-raise",
                 machine,
                 Event.external("go"),
                 executor: &quiet/2
               )

      assert leaves(store, "reentrant-raise", machine) == ["b"]
    end

    # A host that never calls back into the execution it is stepping sees
    # no change: every door, called from the process that just ran a step
    # and its executor, answers exactly what it answered before the
    # refusal existed.
    test "a host that never re-enters sees every door answer as before", %{
      store: store,
      machine: machine
    } do
      create!(store, "reentrant-never", machine)

      assert {:ok, %Execution{status: :active}, _machine_state} =
               Executions.step(
                 store,
                 "reentrant-never",
                 machine,
                 Event.external("go"),
                 executor: &quiet/2
               )

      assert leaves(store, "reentrant-never", machine) == ["b"]
      assert Executions.inputs(store, "reentrant-never") == :not_supported

      assert {:error, :execution_exists} =
               Executions.create(store, "reentrant-never", machine, executor: &quiet/2)

      assert {:ok, %Execution{status: :active}} = Executions.unpark(store, "reentrant-never")

      assert {:ok, %Execution{status: :cancelled}} = Executions.cancel(store, "reentrant-never")

      assert {:discarded, %Execution{status: :cancelled}} =
               Executions.fail(store, "reentrant-never", "late")
    end
  end
end
