defmodule StatifierPersistence.HeldLeaseTest do
  @moduledoc """
  A second `Executions.step/5` for one execution arriving while a first
  one holds the execution's lock: the contract the README's "Delivering
  while a step is in flight" section states.

  The first step is held open from inside its own serialized tail by an
  event builder, which `step/5` resolves under the exclusion it already
  holds; the second is an ordinary `step/5` from another process.

  The Ecto cases run live, outside the SQL sandbox, for
  `EctoLiveLockTest`'s reason: the sandbox funnels every caller through
  one owned connection, so the second step would wait on connection
  ownership rather than on the per-execution lock. The in-memory case
  runs over `StatifierPersistence.Test.InputLogAdapter`, which takes
  `StatifierPersistence.Storage.InMemory`'s own `lock_execution/3` and adds
  the input log that `InMemory` does not keep.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Event
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.Test.{InputLogAdapter, RecordingExecutor}
  alias StatifierPersistence.TestRepo

  # An ad impression that waits for its click, then for the conversion
  # that ends it. "convert" means something only after "click", so the
  # order the two deliveries step in decides how the execution ends.
  @impression """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="served">
      <state id="served">
          <transition event="click" target="clicked"/>
      </state>
      <state id="clicked">
          <transition event="convert" target="converted"/>
      </state>
      <final id="converted"/>
  </scxml>
  """

  @prefix "held-lease-"

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, ecto} = Storage.new(Storage.Ecto, persistence: Default)
    {:ok, machine} = Statifier.compile(@impression)
    %{ecto: ecto, machine: machine}
  end

  setup do
    start_supervised!(RecordingExecutor)
    %{execution_id: @prefix <> "#{System.unique_integer([:positive])}"}
  end

  # sabotage: in Storage.Ecto.lock_execution/3, dropped the
  # pg_advisory_xact_lock query and the FOR UPDATE read, keeping the
  # transaction -> red: the second step/5 returned inside the yield
  # window instead of waiting for the first. Verified red, reverted.
  test "on the Ecto adapter a second step/5 waits for the first, then steps after it",
       %{ecto: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine)

    assert_waits_then_steps(store, execution_id, machine)
  end

  # sabotage: in Storage.Ecto.lock_execution/3, dropped the
  # pg_advisory_xact_lock query and the FOR UPDATE read, keeping the
  # transaction -> red: the second step/5 returned inside the yield
  # window instead of waiting for the first. Verified red, reverted.
  test "on the Ecto adapter a step the first one's step made terminal is discarded",
       %{ecto: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine)
    {:ok, %{status: :active}, _state} = step(store, execution_id, machine, "click")

    {holder, releaser} = hold(store, execution_id, machine, "convert")
    waiter = Task.async(fn -> step(store, execution_id, machine, "click") end)
    assert Task.yield(waiter, 300) == nil

    releaser.()
    assert {:ok, %{status: :completed}, _state} = Task.await(holder, 5_000)
    assert {:discarded, %{status: :completed}} = Task.await(waiter, 5_000)

    # The discarded delivery reached no interpreter, so the log does not
    # carry it.
    assert [{0, "step", "click"}, {1, "step", "convert"}] = inputs(store, execution_id)
  end

  # sabotage: in Storage.InMemory.acquire_lock/2 (the lock
  # InputLogAdapter delegates to), took the lock whether or not the
  # table already held one -> red: the second step/5 returned
  # inside the yield window instead of waiting for the first. Verified
  # red, reverted.
  test "on the in-memory adapter a second step/5 waits for the first, then steps after it",
       %{machine: machine, execution_id: execution_id} do
    {:ok, store} = Storage.new(InputLogAdapter, [])
    {:ok, _execution, _state} = create(store, execution_id, machine)

    assert_waits_then_steps(store, execution_id, machine)
  end

  # The shared body: the first step holds the lock with "click" in hand,
  # the second arrives with "convert", and the second must neither return
  # nor append before the first lets go.
  defp assert_waits_then_steps(store, execution_id, machine) do
    {holder, releaser} = hold(store, execution_id, machine, "click")

    waiter = Task.async(fn -> step(store, execution_id, machine, "convert") end)
    assert Task.yield(waiter, 300) == nil
    assert inputs(store, execution_id) == []

    releaser.()
    assert {:ok, %{status: :active}, _state} = Task.await(holder, 5_000)

    # "convert" ends the execution only if it stepped after "click".
    assert {:ok, %{status: :completed}, _state} = Task.await(waiter, 5_000)
    assert [{0, "step", "click"}, {1, "step", "convert"}] = inputs(store, execution_id)
  end

  # Starts a step/5 that delivers `name` and holds the execution's lock
  # until the returned fun is called. The builder runs inside the step's
  # serialized tail, so by the time the test hears {:holding, _} the lock
  # is taken and nothing of the step has been written yet.
  defp hold(store, execution_id, machine, name) do
    test_pid = self()

    builder = fn _machine_state ->
      send(test_pid, {:holding, self()})

      receive do
        :release -> {:ok, Event.external(name)}
      end
    end

    holder =
      Task.async(fn ->
        Executions.step(store, execution_id, machine, builder, executor: RecordingExecutor)
      end)

    assert_receive {:holding, holding_pid}, 5_000
    {holder, fn -> send(holding_pid, :release) end}
  end

  defp create(store, execution_id, machine),
    do: Executions.create(store, execution_id, machine, executor: RecordingExecutor)

  defp step(store, execution_id, machine, name),
    do:
      Executions.step(store, execution_id, machine, Event.external(name),
        executor: RecordingExecutor
      )

  # The log as the package reads it back: {seq, door, event name}.
  defp inputs(store, execution_id) do
    {:ok, entries} = Executions.inputs(store, execution_id)
    Enum.map(entries, &{&1.seq, &1.door, &1.event.name})
  end

  defp delete_prefixed do
    pattern = @prefix <> "%"
    TestRepo.delete_all(from(i in Default.Input, where: like(i.execution_id, ^pattern)))
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, ^pattern)))
  end
end
