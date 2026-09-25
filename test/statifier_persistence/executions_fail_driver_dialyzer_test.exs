defmodule StatifierPersistence.ExecutionsFailDriverDialyzerTest do
  @moduledoc """
  Runs `StatifierPersistence.Test.Dialyzer.FailWithDriver`, the fixture the
  gate's Dialyzer stage reads as a host's calls to
  `StatifierPersistence.Executions.fail/4` with `driver:`.

  The Dialyzer half is the gate's own stage: with `step_stop_fields/5`'s
  `opts` narrowed back to `[opt()]` the stage reports both fixture
  functions as having no local return. This half shows the same calls fail
  an execution, so the fixture Dialyzer reads is one that works.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.{Execution, Storage}
  alias StatifierPersistence.Test.Dialyzer.FailWithDriver
  alias StatifierPersistence.Test.RecordingExecutor
  alias StatifierPersistence.Testing.Charts

  setup do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    start_supervised!(RecordingExecutor)
    {_source, machine} = Charts.chart_a()

    {:ok, _execution, _ms} =
      StatifierPersistence.Executions.create(store, "execution-1", machine,
        executor: RecordingExecutor
      )

    %{store: store, machine: machine}
  end

  # sabotage: step_stop_fields/5's opts spec narrowed back to [opt()] -> the
  # gate's Dialyzer stage red, no_return on both fixture functions; and
  # fail/4 answering {:error, :execution_not_found} whenever driver: is set ->
  # red here on the two :ok tests. Both reverted from a copy.
  test "fail/4 with driver: fails an unlinked execution", %{store: store, machine: machine} do
    assert {:ok, %Execution{status: :failed, failure: "host:abandoned"}} =
             FailWithDriver.with_driver(store, machine, "execution-1")

    assert {:ok, %{status: :failed, failure: "host:abandoned"}} =
             Storage.fetch_execution(store, "execution-1")
  end

  test "fail/4 with driver: and serialization: fails an unlinked execution", %{
    store: store,
    machine: machine
  } do
    assert {:ok, %Execution{status: :failed, failure: "host:abandoned"}} =
             FailWithDriver.with_driver_and_serialization(store, machine, "execution-1")
  end

  test "fail/4 with driver: on a missing execution returns the error", %{
    store: store,
    machine: machine
  } do
    assert {:error, :execution_not_found} =
             FailWithDriver.with_driver(store, machine, "absent")
  end
end
