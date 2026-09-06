defmodule StatifierPersistence.RunsInputLogTest do
  @moduledoc """
  ADR-0010's write site, from the outside: which doors append, which do
  not, whose log an entry lands in, and what a cap refusal does to the
  run it refuses on.

  The conformance suite proves the adapter callbacks; this module proves
  the one write site inside `StatifierPersistence.Runs`' serialized unit -
  the half no adapter can be conformant about.
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Runs, Storage}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.InputLogAdapter

  # A parent with one input before its invocation, so a driven run passes
  # through the `:step` door before the `:answer_parent` one.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
      <state id="waiting">
          <transition event="advance" target="calling"/>
      </state>
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

  # A chart resting on a `:pending` invocation, for the two invocation
  # doors a host answers directly.
  @pending_source """
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

  # A chart with no invocation at all, for the doors that need no child.
  @plain_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done"/>
  </scxml>
  """

  describe "the door table (ADR-0010 decision 5)" do
    # sabotage: moved the append out of Runs.stepped/6 and up to the head
    # of step_tail/7, before the terminal-run check -> red here, because
    # the create's own drive never reaches step_tail and the run's log came
    # back holding one entry too few for the wrong reason. Verified red
    # (this case plus three others in this module), reverted.
    test "create appends nothing, and a delivered event appends at the :step door" do
      store = store()
      driver = driver(store, @plain_source, fn _t, _p, _c -> :pending end)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_doors")
      assert {:ok, []} = Runs.inputs(store, "run_doors")

      assert {:ok, run, _ms} = Driver.send_event(driver, "run_doors", Event.external("go"))
      assert run.status == :completed

      assert {:ok, [entry]} = Runs.inputs(store, "run_doors")
      assert entry.seq == 0
      assert entry.door == "step"
      assert entry.event.name == "go"
    end

    # sabotage: hard-coded `:step` in place of `entry` in Runs.stepped/6's
    # append_input/4 call -> red here alone ("6 tests, 1 failure"): the
    # parent's second entry came back at the "step" door instead of
    # "answer_parent", the door an operator reads a child-driven step by.
    # Verified red, reverted.
    test "create -> step -> answer_parent lists exactly those inputs, in order, with doors" do
      store = store()
      {:ok, parent_machine} = Statifier.compile(@parent_source)
      {:ok, child_machine} = Statifier.compile(@child_source)

      driver =
        driver(store, @parent_source, subchart_dispatch(@child_source),
          chart_resolver: parent_resolver(parent_machine)
        )

      assert {:ok, _run, _ms} = Driver.create(driver, "run_parent")
      assert {:ok, _run, _ms} = Driver.send_event(driver, "run_parent", Event.external("advance"))

      child_run_id = Linkage.child_run_id("run_parent", "call", 0)
      child_driver = %{driver | machine: child_machine}

      assert {:ok, child_run, _ms} =
               Driver.send_event(child_driver, child_run_id, Event.external("go"))

      assert child_run.status == :completed

      assert {:ok, entries} = Runs.inputs(store, "run_parent")

      assert Enum.map(entries, &{&1.seq, &1.door, &1.event.name}) == [
               {0, "step", "advance"},
               {1, "answer_parent", "done.invoke.call"}
             ]

      # Decision 7: one log per run, and the child's is its own. The
      # parent's log holds the answer it saw, never the child's inputs.
      assert {:ok, child_entries} = Runs.inputs(store, child_run_id)
      assert Enum.map(child_entries, &{&1.seq, &1.door, &1.event.name}) == [{0, "step", "go"}]
    end

    # sabotage: moved the append to the head of step_tail/7, above the
    # terminal-run check and above resolve_event/2 -> red, both discards
    # below appended entries no interpreter ever saw. Verified red,
    # reverted.
    test "a delivery discarded before the interpreter appends nothing" do
      store = store()
      driver = driver(store, @plain_source, fn _t, _p, _c -> :pending end)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_discard")
      assert {:ok, _run, _ms} = Driver.send_event(driver, "run_discard", Event.external("go"))

      # The run is terminal now, so this delivery never reaches an
      # interpreter at all.
      assert {:discarded, _run} =
               Driver.send_event(driver, "run_discard", Event.external("go"))

      # And this one is declined by the builder Driver.done_invocation/5
      # resolves the answer through: nothing is live under that id.
      assert {:discarded, _run} =
               Driver.done_invocation(driver, "run_discard", "absent", nil)

      assert {:ok, [%{door: "step"}]} = Runs.inputs(store, "run_discard")
    end

    # sabotage: moved the append_input/4 call in Runs.stepped/6 above the
    # Interpreter.handle_event/2 case, so it ran for every event that
    # reached this function -> red here alone ("6 tests, 1 failure"): the
    # discarded delivery appended a second entry the interpreter had
    # refused with :not_running, an input a replay would apply and the run
    # never took. Verified red, reverted.
    test "an event the interpreter refuses as :not_running appends nothing" do
      store = store()
      {:ok, machine} = Statifier.compile(@plain_source)
      executor = fn _effect, _context -> :ok end

      {:ok, _run, _ms} = Runs.create(store, "run_lying", machine, executor: executor)

      {:ok, _run, terminal_ms} =
        Runs.step(store, "run_lying", machine, Event.external("go"), executor: executor)

      # A terminal stored position under an :active status - what a crash
      # between chart completion and record update leaves behind.
      :ok = Storage.update_run(store, "run_lying", terminal_ms, :active)

      assert {:discarded, _run} =
               Runs.step(store, "run_lying", machine, Event.external("go"), executor: executor)

      assert {:ok, [%{seq: 0, door: "step"}]} = Runs.inputs(store, "run_lying")
    end

    # sabotage: replaced Runs.stepped/6's `append_input(store, run_id,
    # entry, event)` with a call that appends unconditionally at every
    # door, by moving it into serialized/5 ahead of the tail -> red here:
    # the fail and cancel doors, which involve no interpreter at all
    # (ADR-0009 decision 3), each appended an entry. Verified red,
    # reverted.
    test "the remaining doors: the two invocation doors append, fail and cancel do not" do
      store = store()
      driver = driver(store, @pending_source, fn _t, _p, _c -> :pending end)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_done")
      assert {:ok, _run, _ms} = Driver.done_invocation(driver, "run_done", "call", "answer")

      assert {:ok, [%{seq: 0, door: "done_invocation"}]} = Runs.inputs(store, "run_done")

      assert {:ok, _run, _ms} = Driver.create(driver, "run_failed")

      assert {:ok, _run, _ms} =
               Driver.failed_invocation(driver, "run_failed", "call", reason: "boom")

      assert {:ok, [%{seq: 0, door: "failed_invocation"}]} = Runs.inputs(store, "run_failed")

      # The two host-driven terminal transitions involve no interpreter,
      # so there is no input for them to append (decision 5's table).
      assert {:ok, _run, _ms} = Driver.create(driver, "run_abandoned")
      assert {:ok, _run} = Runs.fail(store, "run_abandoned", "operator abandoned it")
      assert {:ok, []} = Runs.inputs(store, "run_abandoned")

      assert {:ok, _run, _ms} = Driver.create(driver, "run_cancelled")
      assert {:ok, _run} = Runs.cancel(store, "run_cancelled")
      assert {:ok, []} = Runs.inputs(store, "run_cancelled")
    end

    # sabotage: deleted Runs.append_input/4's `{:error, :input_log_full}
    # -> :ok` clause, letting the cap refusal fall through to the error
    # arm -> red here alone: the capped step returned the refusal and the
    # run never advanced, which is exactly the diagnostic facility
    # breaking the run it is diagnosing. Verified red, reverted.
    test "the cap refuses the append and never the step" do
      {:ok, store} = Storage.new(InputLogAdapter, input_log_cap: 1)
      driver = driver(store, @plain_source, fn _t, _p, _c -> :pending end)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_capped")

      assert {:ok, run, _ms} = Driver.send_event(driver, "run_capped", Event.external("go"))
      assert run.status == :completed

      # A cap of one admits zero inputs: the first append writes the
      # closed marker and refuses (decision 6).
      assert {:ok, [%{seq: 0, event: nil}]} = Runs.inputs(store, "run_capped")
    end
  end

  describe "an adapter that keeps no log" do
    # sabotage: deleted the `:not_supported -> :ok` clause from
    # Runs.append_input/4 -> red with
    # `** (CaseClauseError) no case clause matching: :not_supported` on the
    # first step, which is the whole "an adapter written before ADR-0010
    # sees no behaviour change" promise failing loudly. Verified red,
    # reverted.
    test "runs a chart unchanged, and reports :not_supported for its log" do
      {:ok, store} = Storage.new(InMemory, [])
      driver = driver(store, @plain_source, fn _t, _p, _c -> :pending end)

      refute Storage.input_log_supported?(store)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_no_log")
      assert {:ok, run, _ms} = Driver.send_event(driver, "run_no_log", Event.external("go"))
      assert run.status == :completed

      assert :not_supported = Runs.inputs(store, "run_no_log")
    end
  end

  defp store do
    {:ok, store} = Storage.new(InputLogAdapter, [])
    store
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

  defp subchart_dispatch(child_source) do
    fn "myapp:subchart", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: child_source}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  defp parent_resolver(parent_machine) do
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end
end
