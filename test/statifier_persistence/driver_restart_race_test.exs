defmodule StatifierPersistence.DriverRestartRaceTest do
  @moduledoc """
  The cancel-versus-completion race across a restart: the acceptance
  criterion the async-invocation seam was granted on (sp-e50, campaign-024
  ruling R-c).

  A call dispatched `:pending` outlives the process that started it. Two
  things can then happen to it in either order, on any node: the chart can
  cancel the invocation by leaving the invoking state, and the host can
  answer it. Whichever lands first must win *durably*, and the loser must
  be a discard rather than a delivery - a `done.invoke` steered into a
  chart that has already given up on the call is the defect this file
  exists to catch.

  Every "node" here is a separately built `StatifierPersistence.Driver`
  over the same store. Nothing is carried between them in memory: a driver
  holds no run state, so a fresh one is exactly what a cold node builds,
  and everything that crosses does so through the persisted position -
  `active_invocations` included (`Statifier.Position`).

  ADR-0008 decision 5 extends this file with two more scenarios (sp-nt8
  Phase 6): a durable subchart's child is itself a run this package
  started, and it can complete on any node, so the race above happens
  again one level up. `"cancel versus child completion across a parent
  restart"` is ADR-0007's own scenario replayed where the answering party
  is a child run rather than a bare `:pending` call. `"child completes
  while the parent is mid-restart"` is new to ADR-0008: it is not enough
  for the liveness read to happen somewhere before the step, it has to
  fall under the *same* exclusion as the step it gates, so that scenario
  supplies its own `StatifierPersistence.Serialization` strategy
  (`test/support/blocking_serialization.ex`) to pause the answering
  step's tail at a controlled point and prove nothing can land in the
  gap that opens before it. Both live in their own `describe "durable
  subchart"` block below, built on `Driver`'s `start_child` clause
  (`driver.ex`) rather than the plain single-invocation chart above.
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.BlockingSerialization

  # One asynchronous call with a way out of the invoking state that is not
  # the answer: "timeout" exits "calling" and therefore cancels the
  # invocation. Every state the answer must NOT reach afterwards routes to
  # "leaked", so a delivered-anyway answer is visible in the configuration
  # rather than only in a return value.
  @source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="approved">
          <transition event="done.invoke.call" target="leaked"/>
          <transition event="timeout" target="settled"/>
      </state>
      <state id="refused">
          <transition event="done.invoke.call" target="leaked"/>
      </state>
      <state id="abandoned">
          <transition event="done.invoke.call" target="leaked"/>
      </state>
      <state id="settled"/>
      <state id="leaked"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])

    {:ok, _run, machine_state} =
      Driver.create(cold_node(store), "run_1", initialize: [session_id: "sess_race"])

    # The premise of every test below: the call was started, nothing
    # answered it, and the run is durably at rest with it live. Asserted
    # twice on purpose - once on what the drive returned, once on what
    # comes back through the guarded load, because only the second says
    # the invocation survived `Statifier.Position`'s encoding. An
    # `active_invocations` that lived only in memory would make every
    # cross-restart claim below vacuous.
    assert leaves(machine_state) == ["calling"]
    assert Map.values(machine_state.active_invocations) == ["call"]

    reloaded = position(store)

    assert leaves(reloaded) == ["calling"]
    assert Map.values(reloaded.active_invocations) == ["call"]

    %{store: store}
  end

  # Sabotage: made `late_answer/3` skip its `active_invocations` lookup and
  # always build the event - the cancelled invocation's answer was
  # delivered and the run landed in "leaked".
  test "a cancel that lands first discards the completion", %{store: store} do
    assert {:ok, _run, machine_state} =
             Driver.send_event(cold_node(store), "run_1", Event.external("timeout"))

    assert leaves(machine_state) == ["abandoned"]

    assert {:discarded, run} =
             Driver.done_invocation(cold_node(store), "run_1", "call", %{"ok" => true})

    assert run.status == :active
    assert leaves(position(store)) == ["abandoned"]
  end

  # Sabotage: made `late_answer/3` return `:discard` unconditionally - the
  # completion never reached the chart, the run stayed in "calling", and
  # the late timeout took it to "abandoned" instead of "settled".
  test "a completion that lands first wins and the late cancel finds it", %{store: store} do
    assert {:ok, _run, machine_state} =
             Driver.done_invocation(cold_node(store), "run_1", "call", %{
               "authorization" => "auth_1"
             })

    assert leaves(machine_state) == ["approved"]
    assert machine_state.datamodel["_event"]["origin"] == "#_scxml_sess_race"

    assert {:ok, _run, machine_state} =
             Driver.send_event(cold_node(store), "run_1", Event.external("timeout"))

    assert leaves(machine_state) == ["settled"]
  end

  # Sabotage: had `reenter/5` pass `{:done, failure}` for the failing door -
  # the chart took the done transition and this went red on "refused".
  test "the failure door routes error.communication across the restart", %{store: store} do
    assert {:ok, _run, machine_state} =
             Driver.failed_invocation(cold_node(store), "run_1", "call",
               reason: "timeout",
               attempts: 5
             )

    assert leaves(machine_state) == ["refused"]

    assert machine_state.datamodel["_event"]["data"] == %{
             "reason" => "timeout",
             "attempts" => 5,
             "detail" => :undefined
           }
  end

  # Sabotage: same `late_answer/3` mutation again - the redelivery was
  # stepped a second time and the run landed in "leaked". This is the
  # at-most-once property the seam gets for free from the ordinary
  # answer-and-leave chart, and only for it: a chart that stays in the
  # invoking state after answering has no entry removal to lean on
  # (ADR-0007).
  test "a redelivered completion is discarded once the chart has answered", %{store: store} do
    assert {:ok, _run, machine_state} =
             Driver.done_invocation(cold_node(store), "run_1", "call", %{
               "authorization" => "auth_1"
             })

    assert leaves(machine_state) == ["approved"]

    assert {:discarded, run} = Driver.done_invocation(cold_node(store), "run_1", "call", %{})

    assert run.status == :active
    assert leaves(position(store)) == ["approved"]
  end

  describe "durable subchart (ADR-0008 decision 5)" do
    # One durable subchart invocation with the same shape as `@source`
    # above: "timeout" exits "calling" without an answer (which cascades
    # the child's cancel, driver.ex's `{:cancel_invoke, _}` clause), and
    # every state the child's answer must NOT reach afterwards routes to
    # "leaked".
    @parent_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
        <state id="calling">
            <invoke id="call" type="myapp:subchart"/>
            <transition event="done.invoke.call" target="approved"/>
            <transition event="error.communication.invoke.call" target="refused"/>
            <transition event="timeout" target="abandoned"/>
        </state>
        <state id="approved">
            <transition event="done.invoke.call" target="leaked"/>
            <transition event="timeout" target="settled"/>
        </state>
        <state id="refused">
            <transition event="done.invoke.call" target="leaked"/>
        </state>
        <state id="abandoned">
            <transition event="done.invoke.call" target="leaked"/>
        </state>
        <state id="settled"/>
        <state id="leaked"/>
    </scxml>
    """

    # A plain child with no invoke of its own - what its content resolves
    # to is irrelevant to either race below, only that a child run exists
    # under the derived id and can be cancelled.
    @child_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
        <state id="idle">
            <transition event="go" target="settled"/>
        </state>
        <state id="settled"/>
    </scxml>
    """

    # sabotage: two independent trials, each reverted before the next.
    # (1) dropped the `Runs.cascade_cancel/3` call from `perform/5`'s
    # `{:cancel_invoke, _}` clause (`driver.ex`) - the child stayed
    # `:active` after the parent's timeout, and the `child_record.status
    # == :cancelled` assertion went red; (2) flipped `late_answer/3`'s
    # liveness check to always build the event - the late completion was
    # delivered to the abandoned parent, which reached "leaked", and the
    # final `leaves(...) == ["abandoned"]` assertion went red. Both
    # verified red independently, both reverted.
    test "cancel versus child completion across a parent restart", %{store: store} do
      assert {:ok, _run, machine_state} = Driver.create(cold_subchart_node(store), "run_parent")
      assert leaves(machine_state) == ["calling"]

      child_run_id = Linkage.child_run_id("run_parent", "call", 0)
      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert child_record.status == :active

      assert {:ok, _run, machine_state} =
               Driver.send_event(
                 cold_subchart_node(store),
                 "run_parent",
                 Event.external("timeout")
               )

      assert leaves(machine_state) == ["abandoned"]

      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert child_record.status == :cancelled

      assert {:discarded, run} =
               Driver.done_invocation(cold_subchart_node(store), "run_parent", "call", %{
                 "ok" => true
               })

      assert run.status == :active
      assert leaves(parent_position(store)) == ["abandoned"]
    end

    # Sabotage: moved the liveness read out of the event builder
    # (`late_answer/3`) and into `reenter/5`, reading
    # `Storage.load_run_position/3` once at the top of the function -
    # before `step/5`, before `BlockingSerialization` ever signals entry
    # - instead of inside the builder the step itself calls. The
    # precomputed read still saw the invocation live (nothing had
    # cancelled it yet), so it survived Task B's cancel unchanged and the
    # completion was delivered into the now-abandoned parent's "leaked"
    # transition instead of being discarded. Verified red, reverted.
    test "child completes while the parent is mid-restart", %{store: store} do
      # `create/3` runs under the ordinary default serialization - only
      # the answering `done_invocation/5` call below is paused, via a
      # per-call `serialization:` override rather than a driver-level
      # one, so this line does not block on its own caller.
      driver = cold_subchart_node(store)
      assert {:ok, _run, _ms} = Driver.create(driver, "run_parent")

      test_pid = self()

      task_a =
        Task.async(fn ->
          Driver.done_invocation(driver, "run_parent", "call", %{"ok" => true},
            serialization: {BlockingSerialization, {test_pid, store}}
          )
        end)

      # The rendezvous: `BlockingSerialization` has entered `with_run/3`
      # and is paused before it touches the real per-run exclusion or
      # reads the position at all.
      assert_receive {:entered, blocked_pid}, 1_000

      # Task B runs to completion *during* Task A's pause - not blocked on
      # anything, because Task A has not yet acquired the real lock. This
      # is deliberate: it is what proves the gap exists, so the released
      # Task A had better read fresh rather than trust what it knew
      # before the pause.
      driver_b = cold_subchart_node(store)

      task_b =
        Task.async(fn ->
          Driver.send_event(driver_b, "run_parent", Event.external("timeout"))
        end)

      assert {:ok, _run, ms_b} = Task.await(task_b)
      assert leaves(ms_b) == ["abandoned"]

      child_run_id = Linkage.child_run_id("run_parent", "call", 0)
      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert child_record.status == :cancelled

      send(blocked_pid, :go_ahead)

      # The completion's read happens only now, inside the one exclusion
      # that also runs Task B's cancel - so it sees the cancellation and
      # discards, exactly as the ordinary restart case above does.
      assert {:discarded, run} = Task.await(task_a)
      assert run.status == :active
      assert leaves(parent_position(store)) == ["abandoned"]
    end

    # A driver over `@parent_source`, dispatching every
    # `myapp:subchart` invocation to `@child_source` via `{:start_child,
    # ...}` - the same shape `StatifierBlocks.Runtime.Subchart` emits.
    defp cold_subchart_node(store, opts \\ []) do
      {:ok, machine} = Statifier.compile(@parent_source)

      Driver.new(
        store,
        machine,
        Keyword.merge(
          [
            dispatch: subchart_dispatch(),
            invoke_types: InvokeTypes.new(types: ["myapp:subchart"])
          ],
          opts
        )
      )
    end

    defp subchart_dispatch do
      fn "myapp:subchart", _params, %{invoke_id: invoke_id} ->
        invoke = %Statifier.Effect.Invoke{
          invoke_id: invoke_id,
          type: "myapp:subchart",
          src: nil,
          params: nil,
          content: @child_source,
          autoforward: nil,
          state_index: 0,
          invoke_index: 0,
          macrostep: 0,
          microstep: 0,
          round: 0
        }

        {:start_child, invoke, {:invoke, invoke}}
      end
    end

    # `@parent_source`'s own guarded load - the durable-subchart
    # counterpart of `position/1` above.
    defp parent_position(store) do
      {:ok, machine} = Statifier.compile(@parent_source)
      {:ok, machine_state} = Storage.load_run_position(store, "run_parent", machine)

      machine_state
    end
  end

  # One cold node: a driver that has never seen this run, dispatching every
  # call asynchronously and answering none of them in the drive.
  defp cold_node(store) do
    {:ok, machine} = Statifier.compile(@source)

    Driver.new(store, machine,
      dispatch: fn _type, _params, _context -> :pending end,
      invoke_types: InvokeTypes.new(types: ["myapp:authorize"])
    )
  end

  # What the run is durably at, read back through the guarded load rather
  # than taken from a return value - a discard that returned the right
  # tuple while writing the wrong position would pass otherwise.
  defp position(store) do
    {:ok, machine} = Statifier.compile(@source)
    {:ok, machine_state} = Storage.load_run_position(store, "run_1", machine)

    machine_state
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
