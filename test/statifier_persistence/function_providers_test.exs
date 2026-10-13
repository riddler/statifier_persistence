defmodule StatifierPersistence.FunctionProvidersTest do
  @moduledoc """
  `function_providers:` on the durable path (ADR-0004's 2026-10-13
  Amendment): a host's guard functions reach a resumed execution through
  `StatifierPersistence.Executions.step/5`, `create/4`'s `initialize:` and
  `StatifierPersistence.Driver`, without the host touching
  `Statifier.MachineState`; a list that does not resolve is refused at the
  entry, before any lock, load or write; a durable subchart child does not
  inherit the list.
  """

  use ExUnit.Case, async: true

  defmodule SpyStrategy do
    @moduledoc false
    # A pass-through serialization strategy whose config is the test pid:
    # every exclusion it is asked for is reported, so a test can assert a
    # refusal took none.
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(test_pid, execution_id, fun) do
      send(test_pid, {:with_execution, execution_id})
      {:ok, fun.()}
    end
  end

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.GuardFunctions

  # "decide" takes the guarded transition when `Approved('yes')` evaluates,
  # and falls through to "declined" when it cannot: an unregistered
  # function is an `error.execution`, and the `cond` reads false.
  @guarded_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
      <state id="waiting">
          <transition event="decide" cond="Approved('yes')" target="approved"/>
          <transition event="decide" target="declined"/>
      </state>
      <state id="approved"/>
      <state id="declined"/>
  </scxml>
  """

  # The guard on an eventless transition out of the initial state, so the
  # create's own `initialize/2` is what evaluates it.
  @eventless_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="starting">
      <state id="starting">
          <transition cond="Approved('yes')" target="approved"/>
      </state>
      <state id="approved"/>
  </scxml>
  """

  # A durable subchart parent whose answer is guarded the same way.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
          <transition event="done.invoke.call" cond="Approved('yes')" target="approved"/>
          <transition event="done.invoke.call" target="declined"/>
      </state>
      <state id="approved"/>
      <state id="declined"/>
  </scxml>
  """

  # The child: completes with donedata on "go".
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

  @providers [GuardFunctions]

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  describe "Executions.step/5" do
    # sabotage: dropped `put_function_providers/2` from `step_loaded/8`'s
    # re-stamp -> red, the step fell through to "declined"
    test "a resumed execution evaluates a cond calling a registered guard", %{store: store} do
      machine = compile!(@guarded_source)

      {:ok, _execution, _ms} = Executions.create(store, "execution_1", machine, executor: &ok/2)

      assert {:ok, _execution, machine_state} =
               Executions.step(store, "execution_1", machine, Event.external("decide"),
                 executor: &ok/2,
                 function_providers: @providers
               )

      assert leaves(machine_state) == ["approved"]
      assert {:ok, reloaded} = Storage.load_execution_position(store, "execution_1", machine)
      assert leaves(reloaded) == ["approved"]
    end

    # sabotage: `step_loaded/8` stamped a default list when the option was
    # absent -> red, the step reached "approved"
    test "without the option the guard is not registered and the cond reads false", %{
      store: store
    } do
      machine = compile!(@guarded_source)

      {:ok, _execution, _ms} = Executions.create(store, "execution_1", machine, executor: &ok/2)

      assert {:ok, _execution, machine_state} =
               Executions.step(store, "execution_1", machine, Event.external("decide"),
                 executor: &ok/2
               )

      assert leaves(machine_state) == ["declined"]
      assert machine_state.functions == nil
    end

    # sabotage: `step/5` delivered another event when the option was
    # passed -> red, the two answers differed
    test "a chart calling no host function answers the same with the option and without", %{
      store: store
    } do
      {:ok, machine} = Statifier.compile(@child_source)
      event = Event.external("go")

      results =
        for {execution_id, opts} <- [
              {"plain", []},
              {"with_providers", [function_providers: @providers]}
            ] do
          {:ok, _execution, _ms} =
            Executions.create(store, execution_id, machine, executor: &ok/2)

          {:ok, execution, machine_state} =
            Executions.step(store, execution_id, machine, event, [executor: &ok/2] ++ opts)

          {execution.status, execution.donedata, leaves(machine_state)}
        end

      assert [plain, with_providers] = results
      assert plain == with_providers
      assert plain == {:completed, "child-result", []}
    end

    # sabotage: `check_function_providers/1` answered the bare reason ->
    # red; and, separately, the check moved inside the serialization
    # strategy's fun -> red, the spy reported an exclusion
    test "a list that does not resolve is refused before any lock, load or write", %{
      store: store
    } do
      machine = compile!(@guarded_source)

      {:ok, _execution, _ms} = Executions.create(store, "execution_1", machine, executor: &ok/2)
      {:ok, before} = Storage.fetch_execution(store, "execution_1")

      for {providers, reason} <- [
            {:nope, {:not_a_list, :nope}},
            {[String], {:invalid_provider, String, :_}}
          ] do
        assert {:error, {:function_providers, refused}} =
                 Executions.step(store, "execution_1", machine, Event.external("decide"),
                   executor: &ok/2,
                   function_providers: providers,
                   serialization: {SpyStrategy, self()}
                 )

        assert same_reason?(refused, reason)
      end

      refute_received {:with_execution, _execution_id}
      assert {:ok, ^before} = Storage.fetch_execution(store, "execution_1")
    end
  end

  describe "Executions.create/4" do
    # sabotage: `create_open/4` deleted `:function_providers` from the
    # `initialize:` list -> red, the create stayed in "starting"
    test "function_providers inside initialize: reaches the create's own initialize", %{
      store: store
    } do
      machine = compile!(@eventless_source)

      assert {:ok, _execution, machine_state} =
               Executions.create(store, "execution_1", machine,
                 executor: &ok/2,
                 initialize: [function_providers: @providers]
               )

      assert leaves(machine_state) == ["approved"]
    end

    # sabotage: `check_function_providers/1` answered the bare reason -> red
    test "a list inside initialize: that does not resolve is refused before any lock or write",
         %{store: store} do
      machine = compile!(@eventless_source)

      assert {:error, {:function_providers, {:not_a_list, :nope}}} =
               Executions.create(store, "execution_1", machine,
                 executor: &ok/2,
                 initialize: [function_providers: :nope],
                 serialization: {SpyStrategy, self()}
               )

      refute_received {:with_execution, _execution_id}
      assert {:error, :execution_not_found} = Storage.fetch_execution(store, "execution_1")
    end
  end

  describe "Driver" do
    # sabotage: dropped the `:function_providers` `put_new` from
    # `execution_opts/3` -> red, the step reached "declined"
    test "a driver-level list reaches every step of a resumed execution", %{store: store} do
      driver = Driver.new(store, compile!(@guarded_source), dispatch: &no_dispatch/3)
      driver = %{driver | function_providers: @providers}

      {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      assert {:ok, _execution, machine_state} =
               Driver.send_event(driver, "execution_1", Event.external("decide"))

      assert leaves(machine_state) == ["approved"]
    end

    # sabotage: dropped the `:function_providers` line from `create_opts/2`
    # -> red, the create stayed in "starting"
    test "Driver.new/3 reads the option and a create carries it into initialize:", %{
      store: store
    } do
      driver =
        Driver.new(store, compile!(@eventless_source),
          dispatch: &no_dispatch/3,
          function_providers: @providers
        )

      assert driver.function_providers == @providers
      assert {:ok, _execution, machine_state} = Driver.create(driver, "execution_1")
      assert leaves(machine_state) == ["approved"]
    end

    # sabotage: `execution_opts/3` wrote the driver's list with `put` in
    # place of `put_new` -> red, the step reached "approved"
    test "a per-call list outranks the driver's", %{store: store} do
      driver =
        Driver.new(store, compile!(@guarded_source),
          dispatch: &no_dispatch/3,
          function_providers: @providers
        )

      {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      assert {:ok, _execution, machine_state} =
               Driver.send_event(driver, "execution_1", Event.external("decide"),
                 function_providers: nil
               )

      assert leaves(machine_state) == ["declined"]
    end

    # sabotage: dropped `answer_parent/3`'s entry check -> red, that door
    # answered `:no_parent`
    test "every door that carries an event refuses a list that does not resolve", %{
      store: store
    } do
      good =
        Driver.new(store, compile!(@guarded_source),
          dispatch: &no_dispatch/3,
          serialization: {SpyStrategy, self()}
        )

      {:ok, _execution, _ms} = Driver.create(good, "execution_1")
      assert_received {:with_execution, "execution_1"}
      {:ok, before} = Storage.fetch_execution(store, "execution_1")

      bad = %{good | function_providers: [String]}

      doors = [
        fn -> Driver.create(bad, "execution_2") end,
        fn -> Driver.send_event(bad, "execution_1", Event.external("decide")) end,
        fn -> Driver.done_invocation(bad, "execution_1", "call", nil) end,
        fn -> Driver.failed_invocation(bad, "execution_1", "call", []) end,
        fn -> Driver.answer_parent(bad, "execution_1", {:done, nil}) end,
        fn ->
          Driver.send_event(good, "execution_1", Event.external("decide"),
            function_providers: :nope
          )
        end
      ]

      for door <- doors do
        assert {:error, {:function_providers, _reason}} = door.()
      end

      refute_received {:with_execution, _execution_id}
      assert {:ok, ^before} = Storage.fetch_execution(store, "execution_1")
      assert {:error, :execution_not_found} = Storage.fetch_execution(store, "execution_2")
    end
  end

  describe "durable subchart" do
    # sabotage: dropped `function_providers: nil` from `create_child/6`'s
    # create -> red, the child's create was stamped with the list
    test "the child does not inherit the driver's list; the parent's own steps take it", %{
      store: store
    } do
      test_pid = self()

      after_step = fn execution_id, %MachineState{functions: functions}, _effects ->
        send(test_pid, {:stepped, execution_id, functions})
      end

      driver = parent_driver(store, after_step: after_step)

      assert {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)

      assert_received {:stepped, ^child_execution_id, nil}
      assert_received {:stepped, "execution_1", parent_functions}
      assert is_map(parent_functions)
      assert Map.has_key?(parent_functions, "Approved")
    end

    # sabotage: dropped the `:function_providers` `put_new` from
    # `execution_opts/3` -> red, the parent's answer reached "declined"
    test "the answer path steps the parent with the same list", %{store: store} do
      {:ok, parent_machine} = Statifier.compile(@parent_source, function_providers: @providers)
      {:ok, child_machine} = Statifier.compile(@child_source)

      driver = parent_driver(store, chart_resolver: resolver(parent_machine))

      assert {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)

      assert {:ok, %{status: :completed}, _child_ms} =
               Driver.send_event(
                 %{driver | machine: child_machine},
                 child_execution_id,
                 Event.external("go")
               )

      assert {:ok, parent} = Storage.load_execution_position(store, "execution_1", parent_machine)
      assert leaves(parent) == ["approved"]
    end

    # sabotage: dropped `answer_parent/3`'s entry check -> red, the
    # child's answer was recorded before the parent's step refused
    test "answer_parent/3 refuses a list that does not resolve before it records the answer",
         %{store: store} do
      {:ok, parent_machine} = Statifier.compile(@parent_source, function_providers: @providers)
      {:ok, child_machine} = Statifier.compile(@child_source)

      driver = parent_driver(store)
      assert {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)

      # No `chart_resolver:`, so the child's completion answers no parent
      # and records no answer: the refusal below is the only call that
      # could.
      assert {:ok, %{status: :completed}, _child_ms} =
               Driver.send_event(
                 %{driver | machine: child_machine},
                 child_execution_id,
                 Event.external("go")
               )

      assert {:ok, %{outcome_blob: nil}} = Storage.fetch_execution(store, child_execution_id)

      bad = %{driver | machine: parent_machine, function_providers: [String]}

      assert {:error, {:function_providers, {:invalid_provider, String, _message}}} =
               Driver.answer_parent(bad, child_execution_id, {:done, "child-result"})

      assert {:ok, %{outcome_blob: nil}} = Storage.fetch_execution(store, child_execution_id)
      assert {:ok, parent} = Storage.load_execution_position(store, "execution_1", parent_machine)
      assert leaves(parent) == ["calling"]
    end
  end

  describe "Driver.start_child_at/6" do
    # sabotage: dropped `start_child_at/6`'s `check_start_providers/1` step
    # -> red, the door answered `:ok` and created the child
    test "a list that does not resolve is refused before any child is created or written", %{
      store: store
    } do
      good = fan_out_driver(store)
      assert {:ok, _execution, _ms} = Driver.create(good, "execution_1")
      assert_received {:with_execution, "execution_1"}
      {:ok, before} = Storage.fetch_execution(store, "execution_1")

      bad = %{good | function_providers: [String]}

      assert {:refused, {:function_providers, {:invalid_provider, String, message}}} =
               Driver.start_child_at(bad, "execution_1", fan_out_effect(), 0, 2)

      assert is_binary(message)

      # Checked ahead of the parent's read: a missing parent answers the
      # list's refusal, not `:execution_not_found`.
      assert {:refused, {:function_providers, {:not_a_list, :nope}}} =
               Driver.start_child_at(
                 %{good | function_providers: :nope},
                 "execution_missing",
                 fan_out_effect(),
                 0,
                 2
               )

      refute_received {:with_execution, _execution_id}
      assert {:ok, ^before} = Storage.fetch_execution(store, "execution_1")

      for index <- 0..1 do
        assert {:error, :execution_not_found} =
                 Storage.fetch_execution(
                   store,
                   Linkage.child_execution_id("execution_1", "call", index)
                 )
      end
    end

    # sabotage: `check_start_providers/1` refused every list, as if none
    # resolved -> red, the resolvable list answered
    # `{:refused, {:function_providers, _}}`
    test "a list that resolves starts the child as before", %{store: store} do
      driver = fan_out_driver(store)
      assert {:ok, _execution, _ms} = Driver.create(driver, "execution_1")

      assert :ok = Driver.start_child_at(driver, "execution_1", fan_out_effect(), 0, 2)

      assert {:ok, %{status: :active}} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 0)
               )
    end
  end

  # A fan-out parent: the dispatch leaves the invocation pending, so the
  # children are started only through `start_child_at/6`.
  defp fan_out_driver(store) do
    {:ok, machine} = Statifier.compile(@parent_source, function_providers: @providers)

    Driver.new(store, machine,
      dispatch: fn "myapp:subchart", _params, _context -> :pending end,
      invoke_types: InvokeTypes.new(types: ["myapp:subchart"]),
      function_providers: @providers,
      serialization: {SpyStrategy, self()}
    )
  end

  defp fan_out_effect do
    %Statifier.Effect.Invoke{
      invoke_id: "call",
      type: "myapp:subchart",
      src: nil,
      params: %{},
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end

  defp parent_driver(store, opts \\ []) do
    {:ok, machine} = Statifier.compile(@parent_source, function_providers: @providers)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [
          dispatch: subchart_dispatch(),
          invoke_types: InvokeTypes.new(types: ["myapp:subchart"]),
          function_providers: @providers
        ],
        opts
      )
    )
  end

  defp subchart_dispatch do
    fn "myapp:subchart", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: @child_source}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  defp resolver(parent_machine) do
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source, function_providers: @providers)
    machine
  end

  defp ok(_effect, _context), do: :ok

  defp no_dispatch(_type, _params, _context), do: {:error, :no_dispatch}

  defp same_reason?({:invalid_provider, module, message}, {:invalid_provider, module, :_}),
    do: is_binary(message)

  defp same_reason?(reason, reason), do: true
  defp same_reason?(_refused, _expected), do: false

  defp leaves(machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
