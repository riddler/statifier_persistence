defmodule StatifierPersistence.TelemetryTest do
  @moduledoc """
  The `[:statifier_persistence, ...]` emit sites (ADR-0009, sp-m0i).

  One test per event, each driving a real run through the public API and
  asserting the event's name, its measurement keys and its metadata keys
  against `docs/telemetry.md`'s tables - the contract is frozen by the
  record, so the shape assertions are deliberately exhaustive rather than
  `assert_receive` on a fragment.

  Not `async: true`: `:telemetry` handlers are global, so a handler
  attached here would also see events from a concurrently running async
  module and deliver them into this test's mailbox.
  """

  use ExUnit.Case, async: false

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Send.Routes
  alias StatifierPersistence.{Driver, Run, Runs, Storage, Telemetry}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.{NoChildListingAdapter, NoLockAdapter, RecordingExecutor}
  alias StatifierPersistence.Testing.Charts

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
  # re-entry waiting in the target state.
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

  # A <log> the executor can fail - observational, so its failure never
  # re-enters.
  @log_error_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b">
              <log label="observed"/>
          </transition>
      </state>
      <state id="b"/>
  </scxml>
  """

  # An invocation that re-arms itself on every answer: the drive loop's
  # `max_turns` fixture.
  @never_rests_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize"/>
          <transition event="done.invoke.call" target="calling"/>
      </state>
  </scxml>
  """

  # One durable subchart invocation, with a way out that is not the answer.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
      <state id="abandoned"/>
  </scxml>
  """

  # A child that completes with donedata on "go" - the answer fixture.
  @child_done_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done">
          <donedata><content expr="'child-result'"/></donedata>
      </final>
  </scxml>
  """

  @doc false
  # A named handler rather than a closure: `:telemetry` logs a performance
  # warning for a local-function handler on every attach, and a bridge
  # attaches named functions anyway.
  @spec forward(Telemetry.event_name(), map(), map(), %{pid: pid()}) :: :ok
  def forward(name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, measurements, metadata})
    :ok
  end

  setup do
    handler_id = "sp-m0i-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(handler_id, Telemetry.events(), &__MODULE__.forward/4, %{pid: self()})

    on_exit(fn -> :telemetry.detach(handler_id) end)

    start_supervised!(RecordingExecutor)
    {:ok, store} = Storage.new(InMemory, [])

    # The store's own `:init` adapter call is setup, not the test's
    # subject.
    drain()

    %{store: store}
  end

  describe "events/0 (ADR-0009 decision 8)" do
    # Sabotage: dropped @run_lock from @events - the count assertion went
    # red, which is the whole point of a bridge attaching from this list.
    test "returns all fourteen names, unique, under this package's prefix" do
      events = Telemetry.events()

      assert length(events) == 14
      assert Enum.uniq(events) == events

      assert Enum.all?(events, fn [prefix | rest] ->
               prefix == :statifier_persistence and rest != []
             end)
    end

    # Sabotage: renamed the second segment of @child_answered to :children
    # - red, and it is the exact break decision 8 calls breaking.
    test "names every event docs/telemetry.md tables" do
      assert Telemetry.events() == [
               [:statifier_persistence, :run, :step, :start],
               [:statifier_persistence, :run, :step, :stop],
               [:statifier_persistence, :run, :lock],
               [:statifier_persistence, :adapter, :call],
               [:statifier_persistence, :identity, :refused],
               [:statifier_persistence, :run, :created],
               [:statifier_persistence, :run, :terminated],
               [:statifier_persistence, :run, :discarded],
               [:statifier_persistence, :effect, :failed],
               [:statifier_persistence, :drive, :turns_exhausted],
               [:statifier_persistence, :child, :started],
               [:statifier_persistence, :child, :refused],
               [:statifier_persistence, :child, :answered],
               [:statifier_persistence, :child, :cascade_cancelled]
             ]
    end
  end

  describe "the step seam (ADR-0009 decision 5)" do
    # Sabotage: replaced serialized/5's run_step_start/3 call with a bare
    # monotonic reading - the start half never arrived and the pair could
    # not be assembled.
    test "brackets one serialized drive as a start/stop pair sharing one span_ref",
         %{store: store} do
      {_source, machine} = Charts.chart_a()

      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {start_m, start_meta} = await([:statifier_persistence, :run, :step, :start])
      {stop_m, stop_meta} = await([:statifier_persistence, :run, :step, :stop])

      assert Map.keys(start_m) |> Enum.sort() == [:monotonic_time, :system_time]
      assert Map.keys(start_meta) |> Enum.sort() == [:entry, :run_id, :span_ref]
      assert start_meta.run_id == "run-1"
      assert start_meta.entry == :create
      assert is_reference(start_meta.span_ref)

      assert Map.keys(stop_m) |> Enum.sort() == [:duration, :monotonic_time]
      assert stop_m.duration >= 0

      assert Map.keys(stop_meta) |> Enum.sort() == [
               :content_hash,
               :entry,
               :outcome,
               :reason,
               :run_id,
               :session_id,
               :span_ref,
               :status
             ]

      assert stop_meta.span_ref == start_meta.span_ref
      assert stop_meta.outcome == :ok
      assert stop_meta.status == :active
      assert stop_meta.reason == nil
      assert is_binary(stop_meta.content_hash)
      assert is_binary(stop_meta.session_id)
    end

    # Sabotage: made stop_shape/1 report :ok for a discard - red, and a
    # host counting discards would have counted none.
    test "reports outcome :discarded with a nil session_id on a terminal-run discard",
         %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      drain()

      assert {:discarded, %Run{}} =
               Runs.step(store, "run-1", machine, Event.external("finish"),
                 executor: RecordingExecutor
               )

      assert {_m, meta} = await([:statifier_persistence, :run, :step, :stop])
      assert meta.outcome == :discarded
      assert meta.status == :completed
      assert meta.session_id == nil
      assert meta.entry == :step
    end

    # Sabotage: made stop_shape/1's {:error, _} clause report outcome :ok
    # - red; an error that reports as a success is worse than no event.
    test "reports outcome :error with the error term and no status", %{store: store} do
      {_source, machine} = Charts.chart_a()

      assert {:error, :run_not_found} =
               Runs.step(store, "absent", machine, Event.external("go"),
                 executor: RecordingExecutor
               )

      assert {_m, meta} = await([:statifier_persistence, :run, :step, :stop])
      assert meta.outcome == :error
      assert meta.reason == :run_not_found
      assert meta.status == nil
      assert meta.content_hash == nil
    end

    # Sabotage: passed :step for the :fail door in fail/4 - red; the
    # dimension an operator slices step latency by first was wrong.
    test "names the public door each drive came through", %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      {:ok, _run, _ms} = Runs.create(store, "run-2", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run} = Runs.fail(store, "run-1", "operator: abandoned")
      assert {_m, %{entry: :fail}} = await([:statifier_persistence, :run, :step, :stop])

      {:ok, _run} = Runs.cancel(store, "run-2")
      assert {_m, %{entry: :cancel}} = await([:statifier_persistence, :run, :step, :stop])
    end
  end

  describe "[:statifier_persistence, :run, :lock]" do
    # Sabotage: dropped the :acquired emit from inside with_run/3's body -
    # red; the wait for the per-run exclusion is invisible from every
    # other surface.
    test "reports the wait and an :acquired outcome for the default strategy",
         %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {m, meta} = await([:statifier_persistence, :run, :lock])
      assert Map.keys(m) |> Enum.sort() == [:duration, :system_time]
      assert m.duration >= 0
      assert Map.keys(meta) |> Enum.sort() == [:outcome, :reason, :run_id, :strategy]
      assert meta.run_id == "run-1"
      assert meta.outcome == :acquired
      assert meta.reason == nil
      assert meta.strategy == StatifierPersistence.Serialization.AdapterLock
    end

    # Sabotage: dropped the unlocked/4 refusal clause's emit - red; the
    # refusal is invisible from every other surface.
    test "reports an :unavailable outcome with the strategy's own refusal" do
      {:ok, store} = Storage.new(NoLockAdapter, [])
      {_source, machine} = Charts.chart_a()

      assert {:error, {:serialization, :not_supported}} =
               Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {_m, meta} = await([:statifier_persistence, :run, :lock])
      assert meta.outcome == :unavailable
      assert meta.reason == {:serialization, :not_supported}
    end
  end

  describe "[:statifier_persistence, :adapter, :call]" do
    # Sabotage: reported `adapter: nil` - red; "which adapter is slow" is
    # half the question, and the in-memory one no SQL tracer can see.
    test "times every adapter callback with its keys and an :ok outcome", %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      insert = one([:statifier_persistence, :adapter, :call], &(&1.callback == :insert_run))
      {m, meta} = insert

      assert Map.keys(m) |> Enum.sort() == [:duration, :system_time]
      assert m.duration >= 0

      assert Map.keys(meta) |> Enum.sort() == [
               :adapter,
               :callback,
               :content_hash,
               :outcome,
               :reason,
               :run_id,
               :session_id
             ]

      assert meta.adapter == InMemory
      assert meta.outcome == :ok
      assert meta.reason == nil
      assert meta.run_id == "run-1"
      assert meta.session_id == nil
      assert is_binary(meta.content_hash)
    end

    # Sabotage: made call_outcome/1 answer :ok for every result - red;
    # "which storage call is failing" is the question this answers.
    test "reports the adapter's own error arm as the reason", %{store: store} do
      assert {:error, :run_not_found} = Storage.fetch_run(store, "absent")

      assert {_m, meta} = await([:statifier_persistence, :adapter, :call])
      assert meta.callback == :fetch_run
      assert meta.outcome == :error
      assert meta.reason == :run_not_found
      assert meta.run_id == "absent"
    end
  end

  describe "[:statifier_persistence, :identity, :refused]" do
    # Sabotage: emitted the stored Identity struct instead of its content
    # hash - red on is_binary/1, which is exactly the leak ADR-0009
    # decision 7 exists to hold shut.
    test "reports a mismatch as two content hashes and nothing else", %{store: store} do
      {_source, chart_a} = Charts.chart_a()
      {_source, chart_b} = Charts.chart_b()

      {:ok, _run, _ms} = Runs.create(store, "run-1", chart_a, executor: RecordingExecutor)
      drain()

      assert {:error, {:identity_mismatch, _stored, _supplied}} =
               Runs.step(store, "run-1", chart_b, Event.external("go"),
                 executor: RecordingExecutor
               )

      assert {m, meta} = await([:statifier_persistence, :identity, :refused])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :reason,
               :run_id,
               :session_id,
               :stage,
               :stored_content_hash,
               :supplied_content_hash
             ]

      assert meta.stage == :run
      assert meta.reason == :identity_mismatch
      assert meta.run_id == "run-1"
      assert meta.session_id == nil
      assert is_binary(meta.stored_content_hash)
      assert is_binary(meta.supplied_content_hash)
      assert meta.stored_content_hash != meta.supplied_content_hash
    end

    # Sabotage: dropped the emit from persist_tail/6's nil-identity arm -
    # red; a chart with no identity is refused before any write and would
    # otherwise be silent.
    test "reports an unidentified chart with no hashes at all", %{store: store} do
      machine = Charts.unidentified_machine()

      assert {:error, :unidentified_chart} =
               Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      assert {_m, meta} = await([:statifier_persistence, :identity, :refused])
      assert meta.reason == :unidentified_chart
      assert meta.stage == :run
      assert meta.run_id == "run-1"
      assert meta.stored_content_hash == nil
      assert meta.supplied_content_hash == nil
    end
  end

  describe "the run lifecycle seam" do
    # Sabotage: hardcoded `child?: true` - red; a host slicing fan-out by
    # it would have counted every run as a child.
    test "reports a create with child? and metadata? booleans and no map", %{store: store} do
      {_source, machine} = Charts.chart_a()

      {:ok, _run, _ms} =
        Runs.create(store, "run-1", machine,
          executor: RecordingExecutor,
          metadata: %{"tenant" => "t1"}
        )

      assert {m, meta} = await([:statifier_persistence, :run, :created])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :child?,
               :content_hash,
               :metadata?,
               :run_id,
               :session_id
             ]

      assert meta.run_id == "run-1"
      assert meta.child? == false
      assert meta.metadata? == true
      assert is_binary(meta.session_id)
      assert is_binary(meta.content_hash)
    end

    # Sabotage: reported `metadata?` off the merged map rather than the
    # host's half - red once linkage was present, which is the one case
    # the boolean would have lied about.
    test "reports a linked child as child? true and metadata? false", %{store: store} do
      {_source, machine} = Charts.chart_a()
      linkage = Linkage.new("parent-1", "call", 0, "sha256:pinned")

      {:ok, _run, _ms} =
        Runs.create(store, "child-1", machine, executor: RecordingExecutor, linkage: linkage)

      assert {_m, meta} = await([:statifier_persistence, :run, :created])
      assert meta.child? == true
      assert meta.metadata? == false
    end

    # Sabotage: reported driven_by: :host on the chart-driven arm - red;
    # the whole reason this event exists is that the two are different.
    test "reports a chart-driven termination with driven_by :chart", %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {m, meta} = await([:statifier_persistence, :run, :terminated])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :content_hash,
               :driven_by,
               :reason,
               :run_id,
               :session_id,
               :status
             ]

      assert meta.status == :completed
      assert meta.driven_by == :chart
      assert meta.reason == nil
      assert is_binary(meta.session_id)
    end

    # Sabotage: dropped the terminated/4 call from fail_tail/3 - red; a
    # host counting [:statifier, :session, :halt] alone undercounts its own
    # terminations by exactly these.
    test "reports fail/4 and cancel/3 as host-driven terminations", %{store: store} do
      {_source, machine} = Charts.chart_a()
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)
      {:ok, _run, _ms} = Runs.create(store, "run-2", machine, executor: RecordingExecutor)
      drain()

      {:ok, _run} = Runs.fail(store, "run-1", "operator: abandoned")
      assert {_m, failed} = await([:statifier_persistence, :run, :terminated])
      assert failed.status == :failed
      assert failed.driven_by == :host
      assert failed.reason == "operator: abandoned"
      assert failed.session_id == nil

      {:ok, _run} = Runs.cancel(store, "run-2")
      assert {_m, cancelled} = await([:statifier_persistence, :run, :terminated])
      assert cancelled.status == :cancelled
      assert cancelled.driven_by == :host
      assert cancelled.reason == nil
    end

    # Sabotage: passed :terminal_run for the builder's decline - red; the
    # two are different non-events and the vocabulary is closed.
    test "names each of the three ways a delivery becomes a non-event", %{store: store} do
      machine = compile!(@final_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: RecordingExecutor)

      {:ok, _run, terminal_ms} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      drain()

      # 1. the record was already terminal, read before any position decode
      {:discarded, _run} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {m, meta} = await([:statifier_persistence, :run, :discarded])
      assert Map.keys(m) == [:system_time]
      assert Map.keys(meta) |> Enum.sort() == [:entry, :reason, :repaired?, :run_id]
      assert meta.reason == :terminal_run
      assert meta.repaired? == false
      assert meta.entry == :step

      # 2. an event builder declined under the exclusion
      {:ok, _run, _ms} = Runs.create(store, "run-2", machine, executor: RecordingExecutor)
      drain()

      {:discarded, _run} =
        Runs.step(store, "run-2", machine, fn _ms -> :discard end, executor: RecordingExecutor)

      assert {_m, declined} = await([:statifier_persistence, :run, :discarded])
      assert declined.reason == :builder_declined
      assert declined.repaired? == false

      # 3. the record's :active status lied about a terminal position
      :ok = Storage.update_run(store, "run-1", terminal_ms, :active)
      drain()

      {:discarded, _run} =
        Runs.step(store, "run-1", machine, Event.external("finish"), executor: RecordingExecutor)

      assert {_m, repaired} = await([:statifier_persistence, :run, :discarded])
      assert repaired.reason == :position_terminal
      assert repaired.repaired? == true

      # ... and the repair is also a termination, chart-driven
      assert {_m, terminated} = await([:statifier_persistence, :run, :terminated])
      assert terminated.status == :completed
      assert terminated.driven_by == :chart
    end
  end

  describe "[:statifier_persistence, :effect, :failed]" do
    # Sabotage: reported reentered? false unconditionally - red; whether
    # the failure steered the chart is the one thing the event adds over
    # the executor's own return.
    test "reports an actionable failure that re-entered the chart", %{store: store} do
      machine = compile!(@send_error_source)
      executor = failing_executor([:send])
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"),
          executor: executor,
          routes: Routes.new(parent?: true)
        )

      assert {m, meta} = await([:statifier_persistence, :effect, :failed])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :content_hash,
               :executor,
               :kind,
               :reason,
               :reentered?,
               :run_id,
               :session_id
             ]

      assert meta.kind == :send
      assert meta.reason == :down
      assert meta.reentered? == true
      assert meta.executor == :fun
      assert meta.run_id == "run-1"
      assert is_binary(meta.session_id)
      assert is_binary(meta.content_hash)
    end

    # Sabotage: made reenter_one/3's :observational clause report true -
    # red; observation must never look like it steered a run.
    test "reports an observational failure as not re-entered", %{store: store} do
      machine = compile!(@log_error_source)
      executor = failing_executor([:log])
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: executor)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"), executor: executor)

      assert {_m, meta} = await([:statifier_persistence, :effect, :failed])
      assert meta.kind == :log
      assert meta.reentered? == false
    end

    # Sabotage: made executor_name/1's module clause answer :fun - red; a
    # host cannot tell which of its executors is failing without the name.
    test "names a module executor and reports :fun for the arity-2 form", %{store: store} do
      defmodule FailingModule do
        @moduledoc false
        @behaviour StatifierPersistence.Executor

        @impl true
        def execute({:log, _payload}, _context), do: {:error, :module_down}
        def execute(_effect, _context), do: :ok
      end

      machine = compile!(@log_error_source)
      {:ok, _run, _ms} = Runs.create(store, "run-1", machine, executor: FailingModule)
      drain()

      {:ok, _run, _ms} =
        Runs.step(store, "run-1", machine, Event.external("go"), executor: FailingModule)

      assert {_m, meta} = await([:statifier_persistence, :effect, :failed])
      assert meta.executor == FailingModule
      assert meta.reason == :module_down
    end
  end

  describe "[:statifier_persistence, :drive, :turns_exhausted]" do
    # Sabotage: dropped the emit from advance/6's max_turns clause - red;
    # the refusal is a return value nothing else reports.
    test "reports the drive loop's own refusal with the turn count", %{store: store} do
      driver =
        Driver.new(store, compile!(@never_rests_source),
          dispatch: fn _type, _params, _context -> {:ok, %{}} end,
          invoke_types: InvokeTypes.new(types: ["myapp:authorize"]),
          max_turns: 3
        )

      assert {:error, {:turns_exhausted, 3}} = Driver.create(driver, "run-1")

      assert {m, meta} = await([:statifier_persistence, :drive, :turns_exhausted])
      assert Map.keys(m) |> Enum.sort() == [:system_time, :turns]
      assert m.turns == 3
      assert Map.keys(meta) |> Enum.sort() == [:entry, :run_id]
      assert meta.run_id == "run-1"
      assert meta.entry == :create
    end
  end

  describe "the durable-subchart seam (ADR-0008)" do
    # Sabotage: reported a literal hash instead of the linkage's pinned
    # one - red; the pin is what tells a child restarted against a
    # redeployed chart from one that was not.
    test "reports a started child with its pinned hash and its own session",
         %{store: store} do
      driver = subchart_driver(store, @parent_source, @child_done_source)

      assert {:ok, _run, _ms} = Driver.create(driver, "run-1")

      assert {m, meta} = await([:statifier_persistence, :child, :started])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :child_index,
               :child_run_id,
               :content_hash,
               :invoke_id,
               :parent_run_id,
               :session_id
             ]

      assert meta.parent_run_id == "run-1"
      assert meta.child_run_id == Linkage.child_run_id("run-1", "call", 0)
      assert meta.invoke_id == "call"
      assert meta.child_index == 0
      assert is_binary(meta.content_hash)
      assert is_binary(meta.session_id)
      assert meta.content_hash == child_content_hash(@child_done_source)
    end

    # Sabotage: dropped the report_refusal/2 call from start_child/3 - red
    # on the adapter refusal, which never reaches resolve_child/3 at all.
    test "reports every refusal through one site" do
      {:ok, no_children} = Storage.new(NoChildListingAdapter, [])
      driver = subchart_driver(no_children, @parent_source, @child_done_source)

      assert {:ok, _run, _ms} = Driver.create(driver, "run-1")

      assert {m, meta} = await([:statifier_persistence, :child, :refused])
      assert Map.keys(m) == [:system_time]
      assert Map.keys(meta) |> Enum.sort() == [:invoke_id, :parent_run_id, :reason]
      assert meta.parent_run_id == "run-1"
      assert meta.invoke_id == "call"
      assert meta.reason == :child_listing_unsupported

      # Nothing was started, so nothing reports one.
      refute_received {:telemetry, [:statifier_persistence, :child, :started], _m, _meta}
    end

    # Sabotage: hardcoded `outcome: :failed` - red; :done and :failed are
    # the two doors and a consumer counts them apart.
    test "reports a child answering its parent", %{store: store} do
      driver = subchart_driver(store, @parent_source, @child_done_source)
      {:ok, _run, _ms} = Driver.create(driver, "run-1")
      child_run_id = Linkage.child_run_id("run-1", "call", 0)
      drain()

      child_driver = %{driver | machine: compile!(@child_done_source)}

      assert {:ok, _run, _ms} =
               Driver.send_event(child_driver, child_run_id, Event.external("go"))

      assert {m, meta} = await([:statifier_persistence, :child, :answered])
      assert Map.keys(m) == [:system_time]

      assert Map.keys(meta) |> Enum.sort() == [
               :child_run_id,
               :invoke_id,
               :outcome,
               :parent_run_id
             ]

      assert meta.child_run_id == child_run_id
      assert meta.parent_run_id == "run-1"
      assert meta.invoke_id == "call"
      assert meta.outcome == :done
    end

    # Sabotage: made cancel_counted/3 tally an already-terminal run as
    # neither cancelled nor retained - red on the replay, and ADR-0008
    # decision 5's retain semantics stopped being countable.
    test "reports one cascade per public call, with its cancelled and retained counts",
         %{store: store} do
      driver = subchart_driver(store, @parent_source, @child_done_source)
      {:ok, _run, _ms} = Driver.create(driver, "run-1")
      drain()

      assert {:ok, 1} = Runs.cascade_cancel(store, Linkage.invocation_match("run-1", "call"))

      assert {m, meta} = await([:statifier_persistence, :child, :cascade_cancelled])
      assert Map.keys(m) |> Enum.sort() == [:count, :retained, :system_time]
      assert m.count == 1
      assert m.retained == 0
      assert Map.keys(meta) |> Enum.sort() == [:invoke_id, :parent_run_id]
      assert meta.parent_run_id == "run-1"
      assert meta.invoke_id == "call"

      # Re-running the same cascade is a no-op that retains what it finds.
      drain()
      assert {:ok, 0} = Runs.cascade_cancel(store, Linkage.invocation_match("run-1", "call"))

      assert {m, _meta} = await([:statifier_persistence, :child, :cascade_cancelled])
      assert m.count == 0
      assert m.retained == 1
    end

    # Sabotage: read parent_run_id into the invoke_id slot - red; nil is
    # the contract's value for "every invocation".
    test "reports a nil invoke_id for a whole-parent sweep", %{store: store} do
      driver = subchart_driver(store, @parent_source, @child_done_source)
      {:ok, _run, _ms} = Driver.create(driver, "run-1")
      drain()

      assert {:ok, 1} = Runs.cascade_cancel(store, Linkage.parent_match("run-1"))

      assert {_m, meta} = await([:statifier_persistence, :child, :cascade_cancelled])
      assert meta.parent_run_id == "run-1"
      assert meta.invoke_id == nil
    end
  end

  # The first event of `name` in the mailbox, as `{measurements, metadata}`.
  defp await(name) do
    receive do
      {:telemetry, ^name, measurements, metadata} -> {measurements, metadata}
    after
      0 -> flunk("no #{inspect(name)} event was emitted")
    end
  end

  # The first event of `name` whose metadata satisfies `predicate` - for
  # the events a single drive emits several of.
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

  # Drops every event emitted so far, so a phase asserts on its own.
  defp drain do
    receive do
      {:telemetry, _name, _measurements, _metadata} -> drain()
    after
      0 -> :ok
    end
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  defp child_content_hash(source) do
    source |> compile!() |> Statifier.Machine.identity() |> Map.fetch!(:content_hash)
  end

  # An executor failing exactly the given effect kinds.
  defp failing_executor(kinds, reason \\ :down) do
    fn effect, _context ->
      if elem(effect, 0) in kinds, do: {:error, reason}, else: :ok
    end
  end

  # A driver whose dispatch answers `{:start_child, ...}` with the child
  # chart's source inlined as the invocation's content.
  defp subchart_driver(store, parent_source, child_source) do
    dispatch = fn "myapp:subchart", _params, %{invoke: invoke} ->
      resolved = %{invoke | content: child_source}
      {:start_child, resolved, {:invoke, resolved}}
    end

    parent = compile!(parent_source)

    charts =
      Map.new(
        [parent, compile!(child_source)],
        &{Statifier.Machine.identity(&1).content_hash, &1}
      )

    Driver.new(store, parent,
      dispatch: dispatch,
      invoke_types: InvokeTypes.new(types: ["myapp:subchart"]),
      chart_resolver: fn content_hash -> Map.fetch(charts, content_hash) end
    )
  end
end
