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
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Storage.InMemory

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
