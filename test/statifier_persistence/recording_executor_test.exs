defmodule StatifierPersistence.RecordingExecutorTest do
  @moduledoc """
  The test-support `RecordingExecutor` is per test: its Agent carries no
  registered name, so async modules that each start one in `setup` never
  collide, and the module form (`executor: RecordingExecutor`) still finds
  the recorder of the test that is calling it, from the test process or
  from a process the test spawned.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.Test.RecordingExecutor

  setup do
    %{recorder: RecordingExecutor.start!()}
  end

  # sabotage: in RecordingExecutor.start_link/1, registered the Agent with
  # `name: __MODULE__` again -> red, the recorder answered its module name
  # instead of []. Verified red, reverted.
  test "the recorder is started with no registered name", %{recorder: recorder} do
    assert Process.info(recorder, :registered_name) == {:registered_name, []}
    assert Process.whereis(RecordingExecutor) == nil
  end

  # sabotage: in RecordingExecutor.recorder!/0, looked only at the calling
  # process (dropped the `$callers` chain) -> red, the task raised for want
  # of a recorder. Verified red, reverted.
  test "a process the test spawned records into the test's recorder" do
    Task.await(Task.async(fn -> RecordingExecutor.execute({:log, :from_task}, %{}) end))
    RecordingExecutor.execute({:log, :from_test}, %{})

    assert RecordingExecutor.effects() == [{:log, :from_task}, {:log, :from_test}]
  end

  test "reset/0 drops only what this test recorded" do
    RecordingExecutor.execute({:log, :before}, %{})
    assert :ok = RecordingExecutor.reset()
    assert RecordingExecutor.calls() == []
  end

  test "a process with no recorder in reach raises rather than recording nowhere" do
    parent = self()

    spawn(fn ->
      result =
        try do
          RecordingExecutor.execute({:log, :orphan}, %{})
        rescue
          error in RuntimeError -> {:raised, error.message}
        end

      send(parent, {:result, result})
    end)

    assert_receive {:result, {:raised, message}}
    assert message =~ "RecordingExecutor.start!/0"
  end
end
