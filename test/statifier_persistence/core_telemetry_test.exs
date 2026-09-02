defmodule StatifierPersistence.CoreTelemetryTest do
  @moduledoc """
  Family one: the `[:statifier, :session, ...]` events this package emits as
  a stepping driver, with `driver: :persistence` (ADR-0009 decision 2,
  `st-ADR-0067` decisions 2-4, sp-t01).

  These are statifier-ex's own events, emitted from this package's stepper
  seam through `Statifier.Telemetry` rather than reimplemented here, so the
  assertions below are about *applicability and driver* - which events a
  process-less driver emits, from which seam, with which `driver` atom - and
  not about the measurement shapes, which are upstream's contract and are
  produced by upstream's own code.

  Not `async: true`, for `StatifierPersistence.TelemetryTest`'s reason:
  `:telemetry` handlers are global, so a handler attached here would also
  see events from a concurrently running async module.
  """

  use ExUnit.Case, async: false

  alias Statifier.Event
  alias StatifierPersistence.{Runs, Storage}
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.RecordingExecutor
  alias StatifierPersistence.Testing.Charts

  @macrostep_start [:statifier, :session, :macrostep, :start]
  @macrostep_stop [:statifier, :session, :macrostep, :stop]
  @init [:statifier, :session, :init]
  @halt [:statifier, :session, :halt]

  # Reaches a top-level final on "finish": the chart-driven termination.
  @final_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="finish" target="done"/>
      </state>
      <final id="done"/>
  </scxml>
  """

  # An immediate <send> the executor can fail, with the error.communication
  # re-entry waiting in the target state: the `:internal` macrostep span.
  @send_error_source """
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

  # Reaches a top-level final on "finish" AND emits a <send> on the way, so
  # a failing executor collects a failure against an already-halted position.
  @final_with_send_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="finish" target="done">
              <send event="ping" target="#_parent"/>
          </transition>
      </state>
      <final id="done"/>
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

  @doc false
  # A named handler rather than a closure: `:telemetry` logs a performance
  # warning for a local-function handler on every attach.
  @spec forward([atom(), ...], map(), map(), %{pid: pid()}) :: :ok
  def forward(name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, measurements, metadata})
    :ok
  end

  setup do
    handler_id = "sp-t01-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        Statifier.Telemetry.events(),
        &__MODULE__.forward/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_supervised!(RecordingExecutor)
    {:ok, store} = Storage.new(InMemory, [])
    drain()

    %{store: store}
  end

  describe "[:statifier, :session, :init] (st-ADR-0067 decision 3)" do
    # Sabotage: dropped the CoreTelemetry.init/6 call from
    # report_initialized/4 - red, and a bridge would have opened a session
    # it never saw start.
    test "fires once at create, with driver: :persistence and resumed: false",
         %{store: store} do
      {_source, machine} = Charts.chart_a()

      {:ok, _run, machine_state} =
        Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {measurements, metadata} = await(@init)
      assert Map.keys(measurements) == [:system_time]
      assert metadata.driver == :persistence
      assert metadata.resumed == false
      assert metadata.invoked_by == nil
      assert metadata.session_id == machine_state.datamodel["_sessionid"]
      assert metadata.machine_name == machine.name
    end

    # Sabotage: moved the report_initialized/4 call into stepped/6 - red;
    # an :init per load means "process boot", which does not exist here,
    # and would fire thousands of times per logical run.
    test "never fires on a step - every load is a rehydration, not a boot",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"), executor: RecordingExecutor)

      refute_emitted([@init])
    end
  end

  describe "the macrostep span (st-ADR-0067 decision 5)" do
    # Sabotage: passed :event as report_initialized/4's trigger - red; a
    # run's one initialization looked like an external delivery.
    test "brackets Interpreter.initialize/2 at create, as an :initialize pair",
         %{store: store} do
      {_source, machine} = Charts.chart_a()

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {start_m, start_meta} = await(@macrostep_start)
      assert {stop_m, stop_meta} = await(@macrostep_stop)

      assert start_meta.driver == :persistence
      assert start_meta.trigger == :initialize
      assert start_meta.event_name == nil
      assert is_reference(start_meta.span_ref)
      assert Map.keys(start_m) |> Enum.sort() == [:monotonic_time, :system_time]

      assert stop_meta.driver == :persistence
      assert stop_meta.trigger == :initialize
      assert stop_meta.span_ref == start_meta.span_ref
      assert stop_meta.outcome == :quiescent
      assert stop_m.duration >= 0
    end

    # Sabotage: passed :initialize as stepped/6's trigger - red; a host
    # slicing macrostep latency by trigger would see every durable step as
    # an initialization.
    test "brackets Interpreter.handle_event/2 on a step, as an :event pair naming the event",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"), executor: RecordingExecutor)

      assert {_m, start_meta} = await(@macrostep_start)
      assert {_m, stop_meta} = await(@macrostep_stop)

      assert start_meta.trigger == :event
      assert start_meta.event_name == "go"
      assert stop_meta.trigger == :event
      assert stop_meta.event_name == "go"
      assert stop_meta.span_ref == start_meta.span_ref
      assert stop_meta.outcome == :quiescent
      assert stop_meta.driver == :persistence
    end

    # Sabotage: covered by the `running: false` mutation on the test below;
    # no separate local mutation exists, because a terminal run *record*
    # discards in step_tail/8 before the stepper seam is reached at all.
    test "opens no span for a delivery to an already-terminal run", %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      drain()

      # The record now says :completed, so this discards before any decode.
      assert {:discarded, _run} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      refute_emitted([@macrostep_start, @macrostep_stop])
    end

    # Sabotage: dropped the close_macrostep/6 call from deliver_reentry/4 -
    # red; the wave's own effect events then land inside no span at all.
    test "opens a nested :internal span for an error.communication re-entry wave",
         %{store: store} do
      machine = compile!(@send_error_source)

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"),
          executor: failing_executor([:send])
        )

      assert {_m, event_stop} = one(@macrostep_stop, &(&1.trigger == :event))
      assert {_m, internal_start} = one(@macrostep_start, &(&1.trigger == :internal))
      assert {_m, internal_stop} = one(@macrostep_stop, &(&1.trigger == :internal))

      assert internal_start.driver == :persistence
      assert internal_start.event_name == nil
      assert internal_stop.span_ref == internal_start.span_ref
      assert internal_stop.span_ref != event_stop.span_ref
      assert internal_stop.outcome == :quiescent
    end

    # Sabotage: dropped open_macrostep/4's `running: false` clause - red; an
    # :internal start half arrived for a delivery deliver_internal/5 then
    # refused, so its stop half could never exist.
    test "opens no :internal span when the position halted in the same step",
         %{store: store} do
      machine = compile!(@final_with_send_source)

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"),
          executor: failing_executor([:send])
        )

      seen = drain([])

      assert Enum.count(seen, &(&1 == @macrostep_start)) == 1
      assert Enum.count(seen, &(&1 == @macrostep_stop)) == 1
    end

    # Sabotage: made macrostep_outcome/2 always return :quiescent - red;
    # the span said the step settled while the record persisted :failed.
    test "reports outcome :budget_exhausted when the step spends its budget",
         %{store: store} do
      machine = compile!(@loop_after_event_source)

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine,
          executor: RecordingExecutor,
          initialize: [max_macrostep_rounds: 5]
        )

      drain()

      assert {:error, {:budget_exhausted, _payload}} =
               Runs.step(store, "run-1", machine, Event.external("boom"),
                 executor: RecordingExecutor
               )

      assert {_m, stop_meta} = await(@macrostep_stop)
      assert stop_meta.outcome == :budget_exhausted
    end
  end

  describe "[:statifier, :session, :halt]" do
    # Sabotage: removed report_halt/4's call from persist_tail/6 - red; the
    # one event ADR-0040 points "session finished" metrics at was missing
    # for every durable run.
    test "fires with reason :done on the step whose outcome is terminal", %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {measurements, metadata} = await(@halt)
      assert metadata.driver == :persistence
      assert metadata.reason == :done
      # Empty, and correctly so: reaching a top-level final runs
      # `exit_interpreter`, so the halted position has no configuration left
      # - the same shape a session-driven halt reports.
      assert metadata.configuration == MapSet.new()
      assert is_integer(measurements.macrostep)
    end

    # Sabotage: made report_halt/4 read the status rather than the
    # lifecycle effects - red; a budget-exhausted run halted as :done.
    test "fires with reason :budget_exhausted on an exhausted step", %{store: store} do
      machine = compile!(@loop_after_event_source)

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine,
          executor: RecordingExecutor,
          initialize: [max_macrostep_rounds: 5]
        )

      drain()

      assert {:error, {:budget_exhausted, _payload}} =
               Runs.step(store, "run-1", machine, Event.external("boom"),
                 executor: RecordingExecutor
               )

      assert {_m, metadata} = await(@halt)
      assert metadata.reason == :budget_exhausted
    end

    # Sabotage: none available as a local mutation, and that is the point -
    # `fail/4` and `cancel/3` reach no interpreter and hold no
    # `%MachineState{}`, so there is nothing here for a halt to be emitted
    # from. This test is the standing guard against a refactor giving them
    # one and reporting a host abandoning a run as a chart reaching a final
    # state.
    test "never fires for fail/4 or cancel/3 - neither reaches an interpreter",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      {:ok, _run, _ms} = Runs.create(store, "run-2", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run} = Runs.fail(store, "run-1", "operator: abandoned")
      {:ok, _run} = Runs.cancel(store, "run-2")

      refute_emitted([@halt])
    end
  end

  describe "the effect and trace families (st-ADR-0067 decision 3)" do
    # Sabotage: passed `executable` rather than `effects` to
    # report_effects/3 - red; the :done the lifecycle consumes is exactly
    # the effect the bridge needs to see a run finish.
    test "reports every effect the advance produced, lifecycle ones included",
         %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {_m, metadata} = await([:statifier, :session, :effect, :done])
      assert metadata.driver == :persistence
      assert is_binary(metadata.session_id)
    end

    # Sabotage: filtered `{:trace, _}` out of report_effects/3 - red; the
    # nine trace names a host turned `trace: true` on to see were the ones
    # that never arrived.
    test "reports the trace family under trace: true, and nothing under the default",
         %{store: store} do
      {_source, machine} = Charts.chart_a()

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      refute_emitted([[:statifier, :session, :trace, :entry_set]])

      {:ok, _run, _ms} =
        Runs.create(store, "run-2", machine,
          executor: RecordingExecutor,
          initialize: [trace: true]
        )

      assert {_m, metadata} = await([:statifier, :session, :trace, :entry_set])
      assert metadata.driver == :persistence
    end
  end

  describe "the events this driver never emits (st-ADR-0067 decision 3)" do
    # Sabotage: added a CoreTelemetry.terminate/5 call beside report_halt/4 -
    # red; the event names a GenServer callback that does not exist here,
    # and the bridge's per-session cleanup keys on it.
    test "never emits :terminate or :interpret across a full run", %{store: store} do
      machine = compile!(@final_source)

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine,
          executor: RecordingExecutor,
          initialize: [trace: true]
        )

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      refute_emitted([
        [:statifier, :session, :terminate],
        [:statifier, :session, :interpret]
      ])
    end
  end

  # -- helpers -------------------------------------------------------------

  defp await(name) do
    receive do
      {:telemetry, ^name, measurements, metadata} -> {measurements, metadata}
    after
      0 -> flunk("no #{inspect(name)} event was emitted")
    end
  end

  # The first event of `name` whose metadata satisfies `predicate` - for the
  # events one drive emits several of.
  defp one(name, predicate) do
    receive do
      {:telemetry, ^name, measurements, metadata} ->
        if predicate.(metadata), do: {measurements, metadata}, else: one(name, predicate)

      {:telemetry, _other, _measurements, _metadata} ->
        one(name, predicate)
    after
      0 -> flunk("no matching #{inspect(name)} event was emitted")
    end
  end

  # Drains the whole mailbox and asserts none of `names` was among it: a
  # "never emitted" claim read off a selective receive would pass the moment
  # a different event arrived first, which is no assertion at all.
  defp refute_emitted(names) do
    seen = drain([])

    Enum.each(names, fn name ->
      refute name in seen, "#{inspect(name)} was emitted"
    end)
  end

  defp drain do
    _seen = drain([])
    :ok
  end

  defp drain(seen) do
    receive do
      {:telemetry, name, _measurements, _metadata} -> drain([name | seen])
    after
      0 -> seen
    end
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  # An executor failing exactly the given effect kinds.
  defp failing_executor(kinds, reason \\ :down) do
    fn effect, _context ->
      if elem(effect, 0) in kinds, do: {:error, reason}, else: :ok
    end
  end
end
