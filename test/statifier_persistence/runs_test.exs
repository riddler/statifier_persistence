defmodule StatifierPersistence.RunsTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Log
  alias Statifier.Event
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Send.Routes
  alias StatifierPersistence.{Run, Runs, Storage}
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.RecordingExecutor
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

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    start_supervised!(RecordingExecutor)
    %{store: store}
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
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
end
