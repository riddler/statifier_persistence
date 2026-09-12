defmodule StatifierPersistence.DriverTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Storage.InMemory

  # One call, answered or refused, with a plain state on each side so the
  # execution stays active and its position stays readable either way.
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

  # The same one call, with spec 6.4's `src` on it: a URI the core never
  # dereferences (st-ADR-0031) and a document id the host resolves. It is
  # the field `t:Driver.dispatch_context/0`'s `:invoke` key exists to
  # deliver.
  @src_call_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize" src="chart://approval/v3"/>
          <transition event="done.invoke.call" target="approved"/>
      </state>
      <state id="approved"/>
  </scxml>
  """

  # Two calls from one state, and a transition off the first that exits
  # it. The second answer is therefore for an invocation the chart has
  # cancelled by the time its turn comes; `leaked` is where the execution lands
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

  # Waits for an external event before calling, so an execution can be created,
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

  # Two calls in sequence, each answered where it is dispatched, ending in
  # a final state: one create and two answer-fed steps, the last of which
  # produces the `{:done, _}` lifecycle effect no executor ever sees.
  @three_step_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="first">
      <state id="first">
          <invoke id="one" type="myapp:authorize"/>
          <transition event="done.invoke.one" target="second"/>
      </state>
      <state id="second">
          <invoke id="two" type="myapp:capture"/>
          <transition event="done.invoke.two" target="settled"/>
      </state>
      <final id="settled"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  describe "create/3" do
    # Sabotage: forced `advance/6` down its discard branch (`if false`) -
    # no answer was ever stepped and the execution stayed in "calling".
    test "performs the chart's call and steps the answer back in", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn type, params, context ->
            send(test_pid, {:dispatched, type, params, context})
            {:ok, %{"authorization" => "auth_1"}}
          end
        )

      assert {:ok, execution, machine_state} = Driver.create(driver, "execution_1")

      assert execution.status == :active
      assert leaves(machine_state) == ["approved"]
      assert_received {:dispatched, "myapp:authorize", params, context}
      assert params == %{"amount" => 100}
      assert context.execution_id == "execution_1"
    end

    # Sabotage: misspelled `create_opts/2`'s `:initialize` key - the snapshot
    # never reached the core, no <invoke> effect was emitted, and the execution
    # rested in "calling" with nothing dispatched.
    test "registers the driver's invoke types on the creating step", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, machine_state} = Driver.create(driver, "execution_1")
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

      assert {:ok, _execution, machine_state} = Driver.create(driver, "execution_1")

      assert leaves(machine_state) == ["refused"]

      assert machine_state.datamodel["_event"]["data"] == %{
               "reason" => "declined",
               "attempts" => 3,
               "detail" => :undefined
             }
    end

    # Sabotage: made `live?/2` return true unconditionally - the discarded
    # answer was delivered and the execution landed in "leaked".
    test "discards an answer whose invocation the chart has cancelled", %{store: store} do
      driver = driver(store, @two_calls_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, machine_state} = Driver.create(driver, "execution_1")
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

      assert {:error, {:turns_exhausted, 3}} = Driver.create(driver, "execution_1")
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

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")
      assert_received {:effect, {:invoke, _payload}}
    end
  end

  describe "send_event/4" do
    # Sabotage: had `send_event/4` pass `[]` instead of the drained answers
    # to `advance/6` - the execution rested in "calling" and this went red.
    test "drives a resumed execution to quiescence with the original origin", %{store: store} do
      opened = driver(store, @deferred_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, machine_state} =
               Driver.create(opened, "execution_1", initialize: [session_id: "sess_first"])

      assert leaves(machine_state) == ["idle"]

      # A driver built after the fact, as a cold node would build one.
      resumed = driver(store, @deferred_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, machine_state} =
               Driver.send_event(resumed, "execution_1", Event.external("go"))

      assert leaves(machine_state) == ["approved"]
      assert machine_state.datamodel["_event"]["origin"] == "#_scxml_sess_first"
    end

    # Sabotage: made `advance/6`'s no-answers clause return `{:error, :bug}`
    # instead of the step's own result - the discard stopped being what a
    # drive hands back.
    test "returns a terminal execution's discard without dispatching", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn _t, _p, _c ->
            send(test_pid, :dispatched)
            {:ok, %{}}
          end
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")
      assert_received :dispatched

      {:ok, _execution} =
        StatifierPersistence.Executions.fail(store, "execution_1", "host:stopped")

      assert {:discarded, execution} =
               Driver.send_event(driver, "execution_1", Event.external("go"))

      assert execution.status == :failed
      refute_received :dispatched
    end
  end

  describe "done_invocation/5 and failed_invocation/5" do
    # Sabotage: had `perform/5`'s `:pending` arm fall through to
    # `buffer/4` with `{:done, :pending}` - the drive answered a call
    # nobody had made and the execution left "calling".
    test "a pending call rests the execution with the invocation live", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> :pending end)

      assert {:ok, execution, machine_state} = Driver.create(driver, "execution_1")

      assert execution.status == :active
      assert leaves(machine_state) == ["calling"]
      assert Map.values(machine_state.active_invocations) == ["call"]
    end

    # Sabotage: dropped the `Map.put(context, :invoke_id, ...)` from
    # `perform/5` - the dispatch context had no id to key a job by and the
    # assertion went red on a missing key.
    test "hands the invocation's id to the dispatch fun", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @one_call_source,
          dispatch: fn _type, _params, context ->
            send(test_pid, {:context, context})
            :pending
          end
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      assert_received {:context, context}
      assert context.invoke_id == "call"
      assert context.execution_id == "execution_1"
    end

    # Sabotage: made `late_answer/3` return `:discard` unconditionally -
    # the answer never reached the chart and the execution stayed in "calling".
    test "steps a late done answer back into the chart", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> :pending end)

      assert {:ok, _execution, _machine_state} =
               Driver.create(driver, "execution_1", initialize: [session_id: "sess_first"])

      # A driver built after the fact, as the answering job's node builds one.
      answering = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> :pending end)

      assert {:ok, execution, machine_state} =
               Driver.done_invocation(answering, "execution_1", "call", %{
                 "authorization" => "auth_1"
               })

      assert execution.status == :active
      assert leaves(machine_state) == ["approved"]
      assert machine_state.datamodel["_event"]["name"] == "done.invoke.call"
      assert machine_state.datamodel["_event"]["origin"] == "#_scxml_sess_first"
      assert machine_state.datamodel["_event"]["data"] == %{"authorization" => "auth_1"}
    end

    # Sabotage: had `failed_invocation/5` build a `{:done, failure}` answer
    # - the chart took the approved transition and this went red on
    # "refused".
    test "steps a late permanent failure back in as error.communication", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> :pending end)

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      assert {:ok, _execution, machine_state} =
               Driver.failed_invocation(driver, "execution_1", "call",
                 reason: "declined",
                 attempts: 3
               )

      assert leaves(machine_state) == ["refused"]

      assert machine_state.datamodel["_event"]["data"] == %{
               "reason" => "declined",
               "attempts" => 3,
               "detail" => :undefined
             }
    end

    # Sabotage: narrowed `step_tail/6`'s terminal guard to `[:completed]` -
    # the abandoned execution was loaded and stepped, and the answer reached a
    # execution the host had already ended.
    test "discards a late answer to an execution the host abandoned", %{store: store} do
      driver = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> :pending end)

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      {:ok, _execution} =
        StatifierPersistence.Executions.fail(store, "execution_1", "host:stopped")

      assert {:discarded, execution} = Driver.done_invocation(driver, "execution_1", "call", %{})
      assert execution.status == :failed
    end
  end

  describe "dispatch_context" do
    # Sabotage: dropped the `:invoke` key from `perform/5`'s `Map.merge`
    # (driver.ex) - the assertion on `context.invoke` went red with a
    # KeyError on a map with no such key.
    test "carries the whole effect, so a host can read src", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @src_call_source,
          dispatch: fn _type, _params, context ->
            send(test_pid, {:dispatched, context})
            {:ok, %{}}
          end
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      assert_received {:dispatched, context}

      assert %Invoke{
               invoke_id: "call",
               type: "myapp:authorize",
               src: "chart://approval/v3"
             } = context.invoke
    end

    # Sabotage: had `perform/5` put `invoke.invoke_id` under `:invoke` and
    # the struct under `:invoke_id` - every `%{invoke_id: id}` dispatch fun
    # in this suite broke, and this test named the swap directly.
    test "keeps invoke_id beside the effect, unchanged", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @src_call_source,
          dispatch: fn _type, _params, context ->
            send(test_pid, {:dispatched, context})
            {:ok, %{}}
          end
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      assert_received {:dispatched, context}
      assert context.invoke_id == "call"
      assert context.invoke_id == context.invoke.invoke_id
      assert context.execution_id == "execution_1"
      assert is_binary(context.content_hash)
    end
  end

  # ADR-0008's `after_step:` amendment (2026-09-08), the ordinary drive's
  # half. The parent-answer half - clause 2's sentence about the execution id
  # being the execution that was *stepped* - is in `DriverSubchartTest`, where
  # the linked-child fixtures are.
  describe "after_step:" do
    # Sabotage: deleted the `|> fire_after_step(...)` from `create/3`,
    # leaving the one in the private `step/5` - two reports instead of
    # three and this went red on the count (and the cases below it with
    # it, each on its own first report). Verified red, reverted.
    test "fires once per step of a drive, with the driven execution's id", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @three_step_source,
          dispatch: fn _type, _params, _context -> {:ok, %{}} end,
          after_step: reporter(test_pid)
        )

      assert {:ok, execution, _machine_state} = Driver.create(driver, "execution_1")
      assert execution.status == :completed

      reported = reported()

      assert length(reported) == 3

      assert Enum.map(reported, fn {execution_id, _ms, _effects} -> execution_id end) ==
               List.duplicate("execution_1", 3)
    end

    # Sabotage: had `Executions.persist_tail/7` report `executable` rather than
    # the list it was handed - the `{:done, _}` assertion went red while
    # the count above stayed green, which is the whole distinction clause
    # 1 draws. Verified red, reverted.
    test "hands over the whole effect list, lifecycle effects included", %{store: store} do
      test_pid = self()

      driver =
        driver(store, @three_step_source,
          dispatch: fn _type, _params, _context -> {:ok, %{}} end,
          effects: executor_recording_to(test_pid),
          after_step: reporter(test_pid)
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")

      {_execution_id, _machine_state, effects} = List.last(reported())

      assert Enum.any?(effects, &match?({:done, _payload}, &1))
      refute Enum.any?(executed(), &match?({:done, _payload}, &1))
    end

    # Sabotage: wrapped the `after_step.(...)` call in `Driver.report/4`
    # in a `try/rescue` returning `:ok` - the drive answered `{:ok, ...}`
    # and this went red. Verified red, reverted.
    test "a raise inside the callback propagates to the caller", %{store: store} do
      driver =
        driver(store, @three_step_source,
          dispatch: fn _type, _params, _context -> {:ok, %{}} end,
          after_step: fn _execution_id, _machine_state, _effects -> raise "boom" end
        )

      assert_raise RuntimeError, "boom", fn -> Driver.create(driver, "execution_1") end
    end

    # Sabotage: had `Executions.step_tail/7`'s terminal-execution arm report `[]`
    # through the `step_reporter:` before discarding, AND relaxed
    # `Driver.report/4`'s `{:ok, _, _}` head to a catch-all - the discard
    # fired the host's callback and this went red. Both halves were
    # needed, which is the point: nothing persisted means nothing to
    # report, and the driver checks the entry point's own result again on
    # its side of the seam. Verified red, reverted.
    test "a discarded delivery fires nothing", %{store: store} do
      test_pid = self()
      quiet = driver(store, @one_call_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, _machine_state} = Driver.create(quiet, "execution_1")

      {:ok, _execution} =
        StatifierPersistence.Executions.fail(store, "execution_1", "host:stopped")

      reporting = %{quiet | after_step: reporter(test_pid)}

      assert {:discarded, execution} =
               Driver.send_event(reporting, "execution_1", Event.external("go"))

      assert execution.status == :failed
      assert reported() == []
    end

    # Sabotage: made `execution_opts/3` write the `step_reporter:` option
    # unconditionally - a driver that reports nothing still filled this
    # process's mailbox with the reporter's messages and the bare
    # `refute_received` went red. Verified red, reverted.
    test "nil takes the same steps and stores the same position", %{store: store} do
      test_pid = self()
      dispatch = fn _type, _params, _context -> {:ok, %{}} end

      quiet = driver(store, @three_step_source, dispatch: dispatch)
      loud = %{quiet | after_step: reporter(test_pid)}

      assert {:ok, quiet_execution, quiet_state} =
               Driver.create(quiet, "execution_quiet", initialize: [session_id: "sess"])

      # Not just "no report": a driver with no callback puts nothing in
      # the mailbox at all, because it asks for no `step_reporter:`.
      refute_received _anything

      assert {:ok, loud_execution, loud_state} =
               Driver.create(loud, "execution_loud", initialize: [session_id: "sess"])

      assert length(reported()) == 3
      assert quiet_execution.status == loud_execution.status
      assert quiet_execution.donedata == loud_execution.donedata
      assert quiet_state == loud_state
    end

    # The widening the amendment's closing section left open to this bead:
    # the driver's own default, outranked by a per-call `after_step:`.
    #
    # Sabotage: had `execution_opts/3` read `driver.after_step` rather than the
    # effective callback when deciding whether to write a
    # `step_reporter:` - a per-call callback on a driver whose own is
    # `nil` reported nothing and this went red. Verified red, reverted.
    test "a per-call after_step: outranks the driver's own", %{store: store} do
      test_pid = self()
      driver = driver(store, @three_step_source, dispatch: fn _t, _p, _c -> {:ok, %{}} end)

      assert {:ok, _execution, _machine_state} =
               Driver.create(driver, "execution_1", after_step: reporter(test_pid))

      assert length(reported()) == 3
    end
  end

  defp reporter(test_pid) do
    fn execution_id, machine_state, effects ->
      send(test_pid, {:after_step, execution_id, machine_state, effects})
    end
  end

  defp executor_recording_to(test_pid) do
    fn effect, _context ->
      send(test_pid, {:executed, effect})
      :ok
    end
  end

  defp reported(acc \\ []) do
    receive do
      {:after_step, execution_id, machine_state, effects} ->
        reported([{execution_id, machine_state, effects} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp executed(acc \\ []) do
    receive do
      {:executed, effect} -> executed([effect | acc])
    after
      0 -> Enum.reverse(acc)
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
