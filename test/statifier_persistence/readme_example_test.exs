defmodule StatifierPersistence.ReadmeExampleTest do
  @moduledoc """
  The README's "A worked run" section, executed.

  This project has no doctests (the public functions take a live store, not
  values a doctest can print), so a README snippet has nothing checking it
  but this file. Keep the two in step: a change to either is a change to
  both, and the snippets are copied here verbatim apart from the one
  host-side gateway call, which the README leaves to the reader.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Chart, Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Runs, Storage}

  @source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorizing">
    <state id="authorizing">
      <invoke type="myapp:authorize" id="authorize"/>
      <transition event="done.invoke.authorize" target="awaiting_capture"/>
    </state>
    <state id="awaiting_capture">
      <transition event="capture.requested" target="settling"/>
    </state>
    <state id="settling">
      <transition event="ack" target="settled"/>
    </state>
    <final id="settled"/>
  </scxml>
  """

  # sabotage: made `run_status/2` return `:active` where it returns `:completed`
  # for a `:done` machine state (runs.ex) - the final `run.status == :completed`
  # assertion went red, and reverting brought it back.
  test "the README's worked run drives a transaction to settled across a restart" do
    {:ok, machine} = Statifier.compile(@source)
    {:ok, chart_blob} = Chart.to_binary(machine)

    {:ok, store} = Storage.new(StatifierPersistence.Storage.InMemory, [])
    :ok = Storage.save_chart(store, machine, chart_blob)

    parent = self()

    executor = fn
      {:invoke, %Statifier.Effect.Invoke{type: "myapp:authorize"} = invoke}, ctx ->
        send(parent, {:authorized, ctx.run_id, invoke.invoke_id})
        :ok

      _effect, _ctx ->
        :ok
    end

    opts = [executor: executor, invoke_types: InvokeTypes.new(types: ["myapp:authorize"])]

    {:ok, run, state} = Runs.create(store, "txn_01H8", machine, opts)
    assert run.status == :active
    assert config(state) == ["authorizing"]
    assert_received {:authorized, "txn_01H8", "authorize"}

    {:ok, run, state} =
      Runs.step(
        store,
        "txn_01H8",
        machine,
        Event.external("done.invoke.authorize", invokeid: "authorize"),
        opts
      )

    assert run.status == :active
    assert config(state) == ["awaiting_capture"]

    # The restart: only the run id survives.
    {:ok, record} = Storage.fetch_run(store, "txn_01H8")
    {:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, record.content_hash)
    {:ok, rebooted} = Chart.from_binary(blob)

    {:ok, run, state} =
      Runs.step(store, "txn_01H8", rebooted, Event.external("capture.requested"), opts)

    assert run.status == :active
    assert config(state) == ["settling"]

    {:ok, run, state} = Runs.step(store, "txn_01H8", rebooted, Event.external("ack"), opts)
    assert run.status == :completed
    assert config(state) == []
  end

  # The README's own "read the configuration back as state ids" snippet.
  defp config(state) do
    state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(state.machine, &1))
    |> Enum.sort()
  end
end
