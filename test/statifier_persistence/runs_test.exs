defmodule StatifierPersistence.RunsTest do
  use ExUnit.Case, async: true

  defmodule SpyStrategy do
    @moduledoc false
    # A pass-through StatifierPersistence.Serialization strategy whose
    # config is the test pid: it reports every invocation, which is what
    # lets a test assert the serialization: {module, config} opt is
    # honored rather than the default strategy being hardwired.
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_run(test_pid, run_id, fun) do
      send(test_pid, {:with_run, run_id})
      {:ok, fun.()}
    end
  end

  alias Statifier.Effect.{BudgetExhausted, Log, SendDelayed}
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Send.Routes
  alias StatifierPersistence.{Run, Runs, Storage}
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.{FlakyAdapter, NoLockAdapter, RecordingExecutor}
  alias StatifierPersistence.Testing.Charts

  # Reaches top-level final on "finish", executing two <log> blocks in
  # document order on the way - the exact-order assertion's fixture.
  @final_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="finish" target="done">
              <log label="one"/>
              <log label="two"/>
          </transition>
      </state>
      <final id="done"/>
  </scxml>
  """

  # An immediate <send target="#_parent"> whose emission depends on the
  # routes snapshot stamped before the step (ADR-0048): unreachable parent
  # -> rejected in the core, no :send crosses the seam; reachable parent ->
  # the :send effect is emitted.
  @send_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <send event="ping" target="#_parent"/>
          </transition>
      </state>
      <state id="b"/>
  </scxml>
  """

  # A registered <invoke> whose start the executor can fail, and a
  # transition on the error.communication re-entry (st-ADR-0051's
  # failed-communication row).
  @invoke_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <invoke type="myapp:authorize" id="inv1"/>
          <transition event="error.communication" target="errored"/>
      </state>
      <state id="errored"/>
  </scxml>
  """

  # An immediate <send> the executor can fail, with the error.communication
  # transition waiting in the target state.
  @send_error_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <send event="ping" target="#_parent"/>
          </transition>
      </state>
      <state id="b">
          <transition event="error.communication" target="errored"/>
      </state>
      <state id="errored"/>
  </scxml>
  """

  # A <log> the executor can fail - observational, so the run must not
  # take the error.communication transition that would betray a re-entry.
  @log_error_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <log label="observed"/>
          </transition>
      </state>
      <state id="b">
          <transition event="error.communication" target="errored"/>
      </state>
      <state id="errored"/>
  </scxml>
  """

  # The single-wave fixture: the primary :send failure re-enters (b -> c),
  # c's onentry emits another :send whose failure must NOT re-enter - a
  # second wave would land in d.
  @wave_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <send event="ping" target="#_parent"/>
          </transition>
      </state>
      <state id="b">
          <transition event="error.communication" target="c"/>
      </state>
      <state id="c">
          <onentry>
              <send event="pong" target="#_parent"/>
          </onentry>
          <transition event="error.communication" target="d"/>
      </state>
      <state id="d"/>
  </scxml>
  """

  # Quiescent at "idle"; "boom" enters a raise cycle that spends whatever
  # macrostep budget the run was created with.
  @loop_after_event_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="boom" target="loop"/>
      </state>
      <state id="loop">
          <onentry><raise event="tick"/></onentry>
          <transition event="tick" target="loop"/>
      </state>
  </scxml>
  """

  # The same raise cycle entered at initialization, for create-time
  # exhaustion.
  @loop_at_create_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loop">
      <state id="loop">
          <onentry><raise event="tick"/></onentry>
          <transition event="tick" target="loop"/>
      </state>
  </scxml>
  """

  # A delayed <send> with an author id: the deterministic-key fixture for
  # the at-least-once proof (send_id from the author, ordinal from
  # st-ADR-0059's timer_counter).
  @delayed_send_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <send id="ping" event="ping" target="#_parent" delay="1s"/>
          </transition>
      </state>
      <state id="b"/>
  </scxml>
  """

  # The serialization proof's fixture: from s0, the two events reach
  # order-specific final states (e1 then e2 -> s12; e2 then e1 -> s21),
  # while a lost-update interleaving - both steps loading s0 - persists a
  # one-event state (s1 or s2) that no serial order produces. The <log> on
  # every transition gives a slow executor something to stall on, widening
  # the load-to-persist window an unserialized pair would interleave in.
  @order_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <transition event="e1" target="s1"><log label="t1"/></transition>
          <transition event="e2" target="s2"><log label="t2"/></transition>
      </state>
      <state id="s1">
          <transition event="e2" target="s12"><log label="t12"/></transition>
      </state>
      <state id="s2">
          <transition event="e1" target="s21"><log label="t21"/></transition>
      </state>
      <state id="s12"/>
      <state id="s21"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    start_supervised!(RecordingExecutor)
    %{store: store}
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  # The active leaf states as sorted string ids - the readable form of a
  # configuration assertion.
  defp active_ids(%MachineState{} = machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  # An executor failing exactly the given effect tags, recording every call
  # through RecordingExecutor either way.
  defp failing_executor(tags, reason \\ :down) do
    fn effect, context ->
      RecordingExecutor.execute(effect, context)

      if elem(effect, 0) in tags do
        {:error, reason}
      else
        :ok
      end
    end
  end

  describe "create/4" do
    # sabotage: write_run/6 inserts with position: :skip -> red (:run_position_missing)
    test "persists an :active run whose blob decodes to the initialized configuration",
         %{store: store} do
      {_source, machine} = Charts.chart_a()

      assert {:ok, %Run{run_id: "run-1", status: :active, failure: nil}, %MachineState{} = ms} =
               Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {:ok, %{status: :active, failure: nil}} = Storage.fetch_run(store, "run-1")
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert loaded.configuration == ms.configuration
    end

    # sabotage: persist_tail/6 swallows write_run/6's result and returns {:ok, ...} -> red
    test "on an existing run id returns {:error, :run_exists}", %{store: store} do
      {_source, machine} = Charts.chart_a()

      assert {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {:error, :run_exists} =
               Runs.create(store, "run-1", machine, executor: RecordingExecutor)
    end
  end

  describe "step/5" do
    # sabotage: write_run/6 updates with position: :skip -> red (stored config stays initial)
    test "advances the position and persists it", %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, initial} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {:ok, %Run{status: :active}, %MachineState{} = stepped} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: RecordingExecutor
               )

      refute stepped.configuration == initial.configuration
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert loaded.configuration == stepped.configuration
    end

    # sabotage: execute_effects/3 reverses the effect list before executing -> red
    test "hands effects to the executor in list order, excluding :done", %{store: store} do
      machine = compile!(@final_chart_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      RecordingExecutor.reset()

      assert {:ok, _run, _ms} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      assert [{:log, %Log{label: "one"}}, {:log, %Log{label: "two"}}] =
               RecordingExecutor.effects()
    end

    # sabotage: run_status/2 drops the status == :done -> :completed arm -> red
    test "a chart reaching top-level final completes the run and consumes {:done, _}",
         %{store: store} do
      machine = compile!(@final_chart_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {:ok, %Run{status: :completed}, %MachineState{status: :done}} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      assert {:ok, %{status: :completed}} = Storage.fetch_run(store, "run-1")
      refute Enum.any?(RecordingExecutor.effects(), &match?({:done, _}, &1))
    end

    # sabotage: Run.from_record/1 hardcodes status: :active -> red
    test "on a completed run discards without invoking the executor", %{store: store} do
      machine = compile!(@final_chart_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, %Run{status: :completed}, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      RecordingExecutor.reset()

      assert {:discarded, %Run{run_id: "run-1", status: :completed}} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      assert RecordingExecutor.calls() == []
    end

    # sabotage: repair_terminal/3 skips the Storage.update_run/5 repair -> red (record stays :active)
    test "a run record whose :active status lies about a terminal position is discarded and repaired",
         %{store: store} do
      machine = compile!(@final_chart_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, _run, terminal_ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      # Hand-write the lie: a terminal stored position under an :active
      # status, the state a crash between chart completion and record
      # update would leave behind.
      :ok = Storage.update_run(store, "run-1", terminal_ms, :active)
      RecordingExecutor.reset()

      assert {:discarded, %Run{status: :completed}} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      assert RecordingExecutor.calls() == []
      assert {:ok, %{status: :completed}} = Storage.fetch_run(store, "run-1")
    end

    # sabotage: Executor.run/3's fun clause returns :ok without calling the fun -> red
    test "accepts an arity-2 fun as executor and passes the run context", %{store: store} do
      machine = compile!(@final_chart_source)
      parent = self()

      fun = fn effect, context ->
        send(parent, {:executed, effect, context})
        :ok
      end

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: fun)

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: fun)

      content_hash = Machine.identity(machine).content_hash

      assert_receive {:executed, {:log, %Log{label: "one"}},
                      %{run_id: "run-1", content_hash: ^content_hash}}
    end

    # sabotage: step_loaded/6 skips the put_routes/2 re-stamp -> red (the :send is emitted anyway)
    test "stamps the routes snapshot onto the loaded position before the step",
         %{store: store} do
      machine = compile!(@send_chart_source)

      # Parent declared unreachable: the core rejects the <send> against
      # the stamped snapshot, so no :send effect crosses the seam. An
      # unstamped (nil) snapshot would have emitted it - "no determination
      # made" - which is what makes this assert the stamp itself.
      {:ok, _run, _ms} = Runs.create(store, "run-blocked", machine, executor: RecordingExecutor)
      RecordingExecutor.reset()

      {:ok, _run, _ms} =
        Runs.step(store, "run-blocked", machine, Event.external("go"),
          executor: RecordingExecutor,
          routes: Routes.new()
        )

      refute Enum.any?(RecordingExecutor.effects(), &match?({:send, _}, &1))

      # Parent declared reachable: the same chart emits the :send.
      {:ok, _run, _ms} = Runs.create(store, "run-open", machine, executor: RecordingExecutor)
      RecordingExecutor.reset()

      {:ok, _run, _ms} =
        Runs.step(store, "run-open", machine, Event.external("go"),
          executor: RecordingExecutor,
          routes: Routes.new(parent?: true)
        )

      assert Enum.any?(
               RecordingExecutor.effects(),
               &match?({:send, %{event: "ping", target: "#_parent"}}, &1)
             )
    end

    # sabotage: step/5's fetch error arm rewrites the reason -> red
    test "on a missing run returns {:error, :run_not_found}", %{store: store} do
      {_source, machine} = Charts.chart_a()

      assert {:error, :run_not_found} =
               Runs.step(store, "absent", machine, Event.external("go"),
                 executor: RecordingExecutor
               )
    end
  end

  describe "error re-entry (ADR-0004 decision 4)" do
    # sabotage: reentry_origin/1's :invoke clause returns :observational -> red (run stays in b)
    test "a failed :invoke re-enters as error.communication and the persisted position reflects it",
         %{store: store} do
      machine = compile!(@invoke_chart_source)
      executor = failing_executor([:invoke])
      invoke_types = InvokeTypes.new(types: ["myapp:authorize"])

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine, executor: executor, invoke_types: invoke_types)

      assert {:ok, %Run{status: :active}, %MachineState{} = stepped} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: executor,
                 invoke_types: invoke_types
               )

      assert active_ids(stepped) == ["errored"]
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert active_ids(loaded) == ["errored"]
    end

    # sabotage: reentry_origin/1's :send clause returns :observational -> red (run stays in b)
    test "a failed :send re-enters as error.communication the same way", %{store: store} do
      machine = compile!(@send_error_chart_source)
      executor = failing_executor([:send])

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)

      assert {:ok, %Run{status: :active}, stepped} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: executor,
                 routes: Routes.new(parent?: true)
               )

      assert active_ids(stepped) == ["errored"]
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert active_ids(loaded) == ["errored"]
    end

    # sabotage: reentry_origin/1's catch-all re-enters as {:state, 0} -> red (run lands in errored)
    test "a failed :log is discarded and the run is unaffected", %{store: store} do
      machine = compile!(@log_error_chart_source)
      executor = failing_executor([:log])

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)

      assert {:ok, %Run{status: :active}, stepped} =
               Runs.step(store, "run-1", machine, Event.external("go"), executor: executor)

      assert active_ids(stepped) == ["b"]
      assert Enum.any?(RecordingExecutor.effects(), &match?({:log, %Log{label: "observed"}}, &1))
    end

    # sabotage: reenter_one/4 re-enters the wave's own failures recursively -> red (run lands in d)
    test "re-entry is single-wave: a deterministically failing executor terminates in one wave",
         %{store: store} do
      machine = compile!(@wave_chart_source)
      executor = failing_executor([:send, :log, :datamodel_change, :datamodel_init, :cancel])

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)

      assert {:ok, %Run{status: :active}, stepped} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: executor,
                 routes: Routes.new(parent?: true)
               )

      # The primary :send failure re-entered (b -> c); c's onentry :send
      # failed too, and that failure was dropped, not re-entered - a second
      # wave would have landed in d.
      assert active_ids(stepped) == ["c"]
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert active_ids(loaded) == ["c"]
    end
  end

  describe "budget exhaustion" do
    # sabotage: write_run/6 persists the exhausted position (always {:persist, nil}) -> red
    test "at step: run fails, prior blob stays intact, the error surfaces after the persist",
         %{store: store} do
      machine = compile!(@loop_after_event_source)

      {:ok, _run, created} =
        Runs.create(store, "run-1", machine,
          executor: RecordingExecutor,
          initialize: [max_macrostep_rounds: 5]
        )

      assert {:error, {:budget_exhausted, %BudgetExhausted{budget: 5}}} =
               Runs.step(store, "run-1", machine, Event.external("boom"),
                 executor: RecordingExecutor
               )

      assert {:ok, %{status: :failed, failure: "budget_exhausted: 5 rounds"}} =
               Storage.fetch_run(store, "run-1")

      # The pre-step blob remains: the loaded position is the one create
      # persisted, not the non-quiescent exhausted state.
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert loaded.configuration == created.configuration
      assert active_ids(loaded) == ["idle"]
    end

    # sabotage: persist_tail/6 returns {:ok, ...} with no budget_effect/1 case -> red
    test "at create: run fails with no position blob and the error surfaces", %{store: store} do
      machine = compile!(@loop_at_create_source)

      assert {:error, {:budget_exhausted, %BudgetExhausted{budget: 4}}} =
               Runs.create(store, "run-1", machine,
                 executor: RecordingExecutor,
                 initialize: [max_macrostep_rounds: 4]
               )

      assert {:ok, %{status: :failed, failure: "budget_exhausted: 4 rounds"}} =
               Storage.fetch_run(store, "run-1")

      assert {:error, :run_position_missing} =
               Storage.load_run_position(store, "run-1", machine)
    end
  end

  describe "fail/4" do
    # sabotage: fail/4 returns {:ok, ...} without calling Storage.update_run_status/4 -> red
    test "on an active run persists :failed with the reason, position untouched",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, created} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {:ok, %Run{status: :failed, failure: "operator: abandoned"}} =
               Runs.fail(store, "run-1", "operator: abandoned")

      assert {:ok, %{status: :failed, failure: "operator: abandoned"}} =
               Storage.fetch_run(store, "run-1")

      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert loaded.configuration == created.configuration
    end

    # sabotage: fail/4 drops the terminal-status head clause -> red ({:ok, ...} on a completed run)
    test "on a terminal run discards without writing", %{store: store} do
      machine = compile!(@final_chart_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, %Run{status: :completed}, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {:discarded, %Run{status: :completed}} =
               Runs.fail(store, "run-1", "operator: abandoned")

      assert {:ok, %{status: :completed, failure: nil}} = Storage.fetch_run(store, "run-1")
    end

    # sabotage: fail/4's fetch error arm rewrites the reason -> red
    test "on a missing run returns {:error, :run_not_found}", %{store: store} do
      assert {:error, :run_not_found} = Runs.fail(store, "absent", "operator: abandoned")
    end
  end

  describe "per-run serialization (ADR-0004 decision 5)" do
    # sabotage: InMemory.lock_run/3 runs fun without the exclusion
    # ({:ok, fun.()} with no acquire) -> red (both steps load s0 and the
    # persisted state is a one-event s1/s2, which no serial order produces)
    test "two concurrent steps on one run serialize to some order of the two events",
         %{store: store} do
      machine = compile!(@order_chart_source)

      # The slow executor stalls each step between load and persist, so an
      # unserialized pair reliably overlaps there instead of racing past
      # each other by luck.
      executor = fn _effect, _context ->
        Process.sleep(50)
        :ok
      end

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)

      tasks =
        for event <- ["e1", "e2"] do
          Task.async(fn ->
            Runs.step(store, "run-1", machine, Event.external(event), executor: executor)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, %Run{status: :active}, %MachineState{}}, &1))

      # The final persisted state is one of the two serial orders' results,
      # never an interleaving's.
      assert {:ok, loaded} = Storage.load_run_position(store, "run-1", machine)
      assert active_ids(loaded) in [["s12"], ["s21"]]
    end

    # sabotage: Runs.serialized/4 ignores the :serialization opt and always
    # uses the {AdapterLock, store} default -> red (no {:with_run, _}
    # message ever arrives)
    test "the serialization: {module, config} override is honored on every entry point",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      serialization = {SpyStrategy, self()}

      assert {:ok, _run, _ms} =
               Runs.create(store, "run-1", machine,
                 executor: RecordingExecutor,
                 serialization: serialization
               )

      assert_receive {:with_run, "run-1"}

      assert {:ok, _run, _ms} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: RecordingExecutor,
                 serialization: serialization
               )

      assert_receive {:with_run, "run-1"}

      assert {:ok, %Run{status: :failed}} =
               Runs.fail(store, "run-1", "operator: abandoned", serialization: serialization)

      assert_receive {:with_run, "run-1"}
    end

    # sabotage: AdapterLock.with_run/3 falls back to {:ok, fun.()} when the
    # adapter exports no lock_run/3 -> red (create returns {:ok, ...} and
    # the run exists)
    test "an adapter without lock_run/3 under the default strategy is refused" do
      {:ok, store} = Storage.new(NoLockAdapter, [])
      {_source, machine} = Charts.chart_a()

      assert {:error, {:serialization, :not_supported}} =
               Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      # The refusal precedes the tail: nothing was inserted.
      assert {:error, :run_not_found} = Storage.fetch_run(store, "run-1")
    end
  end

  describe "at-least-once redelivery" do
    # sabotage: persist_tail/6 swallows write_run/6's error and returns {:ok, ...} -> red
    test "a failed persist re-drives the same event and re-emits identical deterministic keys" do
      {:ok, store} = Storage.new(FlakyAdapter, [])
      machine = compile!(@delayed_send_chart_source)

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      RecordingExecutor.reset()

      # First step: the effect executes, then the injected adapter failure
      # lands exactly where a crash between execute and persist would.
      assert {:error, {:adapter, :injected}} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: RecordingExecutor
               )

      # Re-driving the same event succeeds and re-emits the same effect.
      assert {:ok, %Run{status: :active}, _ms} =
               Runs.step(store, "run-1", machine, Event.external("go"),
                 executor: RecordingExecutor
               )

      assert [{:send_delayed, %SendDelayed{} = first}, {:send_delayed, %SendDelayed{} = second}] =
               RecordingExecutor.effects()

      # Field-level equality of the deterministic keys (st-ADR-0054
      # decision 3, st-ADR-0059), not just list length.
      assert first.send_id == "ping"
      assert second.send_id == first.send_id
      assert second.ordinal == first.ordinal

      assert {second.macrostep, second.microstep, second.round} ==
               {first.macrostep, first.microstep, first.round}

      assert second == first
    end
  end
end
