defmodule StatifierPersistence.DriverTest do
  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Storage.InMemory

  # One call, answered or refused, with a plain state on each side so the
  # run stays active and its position stays readable either way.
  @one_call_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize">
              <param name="amount" expr="100"/>
          </invoke>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  # Two calls from one state, and a transition off the first that exits
  # it. The second answer is therefore for an invocation the chart has
  # cancelled by the time its turn comes; `leaked` is where the run lands
  # if it is delivered anyway.
  @two_calls_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="one" type="myapp:authorize"/>
          <invoke id="two" type="myapp:capture"/>
          <transition event="done.invoke.one" target="settled"/>
      </state>
      <state id="settled">
          <transition event="done.invoke.two" target="leaked"/>
      </state>
      <state id="leaked"/>
  </scxml>
  """

  # A self-transition on the answer, so every answer re-enters the state
  # and re-fires the same call: a chart that never rests.
  @never_rests_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize"/>
          <transition event="done.invoke.call" target="calling"/>
      </state>
  </scxml>
  """

  # Waits for an external event before calling, so a run can be created,
  # dropped, and picked up by a driver built in a later "process".
  @deferred_call_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="calling"/>
      </state>
      <state id="calling">
          <invoke id="call" type="myapp:authorize"/>
          <transition event="done.invoke.call" target="approved"/>
      </state>
      <state id="approved"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  describe "create/3" do
    # Sabotage: forced `advance/6` down its discard branch (`if false`) -
    # no answer was ever stepped and the run stayed in "calling".
    test "performs the chart's call and steps the answer back in", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn type, params, context ->
            send(test_pid, {:dispatched, type, params, context})
            {:ok, %{"authorization" => "auth_1"}}
          end
        )

      assert {:ok, run, machine_state} = Driver.create(driver, "run_1")

      assert run.status == :active
      assert leaves(machine_state) == ["approved"]
      assert_received {:dispatched, "myapp:authorize", params, context}
      assert params == %{"amount" => 100}
      assert context.run_id == "run_1"
    end

    # Sabotage: misspelled `create_opts/2`'s `:initialize` key - the snapshot
    # never reached the core, no <invoke> effect was emitted, and the run
    # rested in "calling" with nothing dispatched.
    test "registers the driver's invoke types on the creating step", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")
      assert leaves(machine_state) == ["approved"]
    end

    # Sabotage: had the failure arm build a `done.invoke.` name - the chart
    # took the approved transition and this went red on "refused".
    test "answers a permanent refusal as error.communication.invoke", %{store: store} do
      driver =
        driver(store, @one_call_source,
          dispatch: fn _type, _params, _context ->
            {:error, reason: "declined", attempts: 3}
          end
        )

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")

      assert leaves(machine_state) == ["refused"]

      assert machine_state.datamodel["_event"]["data"] == %{
               "reason" => "declined",
               "attempts" => 3,
               "detail" => :undefined
             }
    end

    # Sabotage: made `live?/2` return true unconditionally - the discarded
    # answer was delivered and the run landed in "leaked".
    test "discards an answer whose invocation the chart has cancelled", %{store: store} do
      driver = driver(store, @two_calls_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")
      assert leaves(machine_state) == ["settled"]
    end

    # Sabotage: removed the `turns >= max_turns` clause - the drive kept
    # turning and the test went red on ExUnit's timeout, which is the
    # failure this bound exists to prevent.
    test "refuses to keep turning a chart that never rests", %{store: store} do
      driver =
        driver(store, @never_rests_source,
          dispatch: fn _t, _p, _c -> {:ok, %{}} end,
          max_turns: 3
        )

      assert {:error, {:turns_exhausted, 3}} = Driver.create(driver, "run_1")
    end

    # Sabotage: made `observe/3` skip the host executor - nothing arrived
    # and the trace assertion went red.
    test "hands every effect to the host executor before dispatching", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn _t, _p, _c -> {:ok, %{}} end,
          effects: fn effect, _context -> send(test_pid, {:effect, effect}) && :ok end
        )

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_1")
      assert_received {:effect, {:invoke, _payload}}
    end
  end

  describe "send_event/4" do
    # Sabotage: had `send_event/4` pass `[]` instead of the drained answers
    # to `advance/6` - the run rested in "calling" and this went red.
    test "drives a resumed run to quiescence with the original origin", %{store: store} do
      opened = driver(store, @deferred_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _run, machine_state} =
               Driver.create(opened, "run_1", initialize: [session_id: "sess_first"])

      assert leaves(machine_state) == ["idle"]

      # A driver built after the fact, as a cold node would build one.
      resumed = driver(store, @deferred_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _run, machine_state} =
               Driver.send_event(resumed, "run_1", Event.external("go"))

      assert leaves(machine_state) == ["approved"]
      assert machine_state.datamodel["_event"]["origin"] == "#_scxml_sess_first"
    end

    # Sabotage: made `advance/6`'s no-answers clause return `{:error, :bug}`
    # instead of the step's own result - the discard stopped being what a
    # drive hands back.
    test "returns a terminal run's discard without dispatching", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn _t, _p, _c ->
            send(test_pid, :dispatched)
            {:ok, %{}}
          end
        )

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_1")
      assert_received :dispatched

      {:ok, _run} = StatifierPersistence.Runs.fail(store, "run_1", "host:stopped")

      assert {:discarded, run} = Driver.send_event(driver, "run_1", Event.external("go"))
      assert run.status == :failed
      refute_received :dispatched
    end
  end

  defp driver(store, source, opts) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.put_new(
        opts,
        :invoke_types,
        InvokeTypes.new(types: ["myapp:authorize", "myapp:capture"])
      )
    )
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
