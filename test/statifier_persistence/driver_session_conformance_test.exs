defmodule StatifierPersistence.DriverSessionConformanceTest do
  @moduledoc """
  The assertion `StatifierPersistence.Driver`'s whole reason for existing
  rests on: a chart answered durably sees exactly the event it would have
  seen answered through a live `Statifier.Session`.

  Both halves run the same document with the same session id and the same
  answer. The comparison is `_event` - spec 5.10's system variable, the
  chart's own view of what arrived - rather than the `%Statifier.Event{}`
  struct, because `_event` is the surface a document can actually branch
  on, and a difference invisible there is a difference no chart can see.
  """

  use ExUnit.Case, async: true

  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Session
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.AnsweringHandler

  @session_id "sess_conformance"
  @invoke_type "myapp:authorize"

  @source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:authorize"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  setup do
    {:ok, machine} = Statifier.compile(@source)
    {:ok, store} = Storage.new(InMemory, [])

    %{machine: machine, store: store}
  end

  # Sabotage: dropped the `#_scxml_` prefix from `origin` and nulled
  # `origintype` in `invoked_event/4` - the durable `_event` stopped
  # matching the session's C.1 address and processor URI.
  test "a done answer reaches the chart as the session's own event", context do
    donedata = %{"authorization" => "auth_1", "amount" => 100}

    session_event =
      via_session(context.machine, fn session ->
        Session.done_invocation(session, "call", donedata)
      end)

    durable_event =
      via_driver(context, fn _type, _params, _ctx -> {:ok, donedata} end)

    assert durable_event == session_event
    assert durable_event["name"] == "done.invoke.call"
    assert durable_event["origin"] == "#_scxml_" <> @session_id
  end

  # Sabotage: replaced the failure payload with the reference embedder's
  # `%{"reason" => inspect(reason)}` shape - "attempts" and "detail" went
  # missing and the maps stopped matching.
  test "a permanent refusal reaches the chart as the session's own event", context do
    failure = [reason: "declined", attempts: 3]

    session_event =
      via_session(context.machine, fn session ->
        Session.failed_invocation(session, "call", failure)
      end)

    durable_event = via_driver(context, fn _type, _params, _ctx -> {:error, failure} end)

    assert durable_event == session_event
    assert durable_event["name"] == "error.communication.invoke.call"

    assert durable_event["data"] == %{
             "reason" => "declined",
             "attempts" => 3,
             "detail" => :undefined
           }
  end

  # Starts a live session over the same document, lets `answer` report the
  # invocation through whichever ADR-0051/ADR-0068 door it names, and
  # returns the `_event` the chart then saw.
  defp via_session(machine, answer) do
    opts = [
      session_id: @session_id,
      invoke_handlers: %{@invoke_type => AnsweringHandler}
    ]

    session =
      start_supervised!(%{
        id: :conformance_session,
        start: {Session, :start_link, [machine, opts]}
      })

    :ok = answer.(session)

    Session.snapshot(session).datamodel["_event"]
  end

  # The same document under the durable driver, pinned to the same session
  # id, answered by `dispatch`.
  defp via_driver(%{machine: machine, store: store}, dispatch) do
    driver =
      Driver.new(store, machine,
        dispatch: dispatch,
        invoke_types: InvokeTypes.new(types: [@invoke_type])
      )

    {:ok, _run, machine_state} =
      Driver.create(driver, "run_1", initialize: [session_id: @session_id])

    machine_state.datamodel["_event"]
  end
end
