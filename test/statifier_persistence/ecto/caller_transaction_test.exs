defmodule StatifierPersistence.Ecto.CallerTransactionTest do
  @moduledoc """
  `Executions.create/4` and `Executions.step/5` inside a transaction the
  caller opened on the same repo, in the same process: the contract the
  README's "Writing inside a caller's transaction" section states.

  Live, outside the SQL sandbox, for `EctoLiveLockTest`'s reason: the
  sandbox funnels every caller through one owned connection, so a second
  connection waiting on the caller would be waiting on connection
  ownership, not on the lock. The sandbox also runs the caller's
  `TestRepo.transaction/1` as a savepoint inside its own transaction, so
  a commit there is a savepoint release that nothing outside the test
  can see. Here the caller's transaction is a real `BEGIN` / `COMMIT` on
  a pooled connection.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Log
  alias Statifier.Event
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.Test.RecordingExecutor
  alias StatifierPersistence.TestRepo

  # An ad impression that waits for its click. Both states log on entry,
  # so create/4 and step/5 each hand the executor exactly one effect.
  @impression """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="served">
      <state id="served">
          <onentry><log label="impression_served"/></onentry>
          <transition event="click" target="clicked"/>
      </state>
      <state id="clicked">
          <onentry><log label="click_recorded"/></onentry>
          <transition event="convert" target="converted"/>
      </state>
      <final id="converted"/>
  </scxml>
  """

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    {:ok, machine} = Statifier.compile(@impression)
    %{store: store, machine: machine}
  end

  setup do
    RecordingExecutor.start!()
    %{execution_id: "caller-tx-#{System.unique_integer([:positive])}"}
  end

  # sabotage: in Storage.Ecto.lock_execution/3, ran repo.transaction/1
  # inside Task.async/1 + Task.await/1 (a second pooled connection, not
  # the caller's) -> red: the caller's rollback left the execution row
  # committed behind it (the lock and :execution_exists tests below go
  # red under it too). Verified red, reverted.
  test "a rolled-back caller transaction leaves no execution and no input",
       %{store: store, machine: machine, execution_id: execution_id} do
    assert {:error, :router_gave_up} =
             TestRepo.transaction(fn ->
               {:ok, _execution, _state} = create(store, execution_id, machine)
               {:ok, _execution, _state} = step(store, execution_id, machine, "click")
               TestRepo.rollback(:router_gave_up)
             end)

    assert executions(execution_id) == 0
    assert input_rows(execution_id) == 0

    # Both effects reached the executor before the rollback: nothing the
    # package fires waits for the caller's commit.
    assert logged() == ["impression_served", "click_recorded"]
  end

  # sabotage: in Executions.stepped/7, replaced the append_input/4 call
  # with a bare :ok -> red: the committed transaction kept the execution
  # row and an empty input log. Verified red, reverted.
  test "a committed caller transaction keeps the execution and step/5's input",
       %{store: store, machine: machine, execution_id: execution_id} do
    assert {:ok, :committed} =
             TestRepo.transaction(fn ->
               {:ok, _execution, _state} = create(store, execution_id, machine)
               {:ok, _execution, _state} = step(store, execution_id, machine, "click")
               :committed
             end)

    assert executions(execution_id) == 1
    assert [{0, "step", "click"}] = inputs(store, execution_id)

    # And the execution is an ordinary one afterwards: a later step/5
    # outside any caller's transaction appends at the next ordinal.
    assert {:ok, %{status: :completed}, _state} = step(store, execution_id, machine, "convert")
    assert [{0, "step", "click"}, {1, "step", "convert"}] = inputs(store, execution_id)
  end

  # sabotage: in Storage.Ecto.lock_execution/3, dropped the
  # pg_advisory_xact_lock query and the FOR UPDATE read, keeping the
  # transaction -> red: the second connection's step/5 answered
  # {:error, :execution_not_found} inside the yield window instead of
  # waiting for the caller's commit. Verified red, reverted.
  test "the per-execution lock is held until the caller's transaction commits",
       %{store: store, machine: machine, execution_id: execution_id} do
    test_pid = self()

    committer =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          {:ok, _execution, _state} = create(store, execution_id, machine)
          send(test_pid, :created)

          receive do
            :commit -> :committed
          end
        end)
      end)

    assert_receive :created, 5_000

    # A second connection stepping the same execution waits on the lock
    # create/4 took inside the caller's transaction, not on create/4's
    # own return.
    stepper = Task.async(fn -> step(store, execution_id, machine, "click") end)
    assert Task.yield(stepper, 300) == nil

    send(committer.pid, :commit)
    assert {:ok, :committed} = Task.await(committer, 5_000)
    assert {:ok, %{status: :active}, _state} = Task.await(stepper, 5_000)
    assert [{0, "step", "click"}] = inputs(store, execution_id)
  end

  # sabotage: in Storage.Ecto.insert_execution/2 (do_insert_execution/3),
  # passed on_conflict: :nothing to the insert -> red: the duplicate
  # create answered {:ok, ...} instead of {:error, :execution_exists}.
  # Verified red, reverted.
  test "an :execution_exists refusal aborts the caller's transaction",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine)
    RecordingExecutor.reset()

    other_id = execution_id <> "-other"

    result =
      TestRepo.transaction(fn ->
        {:ok, _execution, _state} = create(store, other_id, machine)
        assert {:error, :execution_exists} = create(store, execution_id, machine)

        # The refused INSERT failed inside the caller's transaction, so
        # the connection refuses every later statement until it ends.
        assert_raise Postgrex.Error, ~r/current transaction is aborted/, fn ->
          TestRepo.query!("SELECT 1")
        end

        :unreachable_commit
      end)

    assert {:error, :rollback} = result
    assert executions(other_id) == 0

    # The refused create fired its initialize effects before the insert
    # that refused it, exactly as it does outside a caller's transaction.
    assert logged() == ["impression_served", "impression_served"]
  end

  defp create(store, execution_id, machine),
    do: Executions.create(store, execution_id, machine, executor: RecordingExecutor)

  defp step(store, execution_id, machine, name),
    do:
      Executions.step(store, execution_id, machine, Event.external(name),
        executor: RecordingExecutor
      )

  defp executions(execution_id) do
    TestRepo.aggregate(
      from(e in Default.Execution, where: e.execution_id == ^execution_id),
      :count
    )
  end

  # The <log> labels the executor was handed, in order.
  defp logged, do: for({:log, %Log{label: label}} <- RecordingExecutor.effects(), do: label)

  # The raw row count, readable whether or not the execution row exists.
  defp input_rows(execution_id) do
    TestRepo.aggregate(from(i in Default.Input, where: i.execution_id == ^execution_id), :count)
  end

  # The log as the package reads it back: {seq, door, event name}.
  defp inputs(store, execution_id) do
    {:ok, entries} = Executions.inputs(store, execution_id)
    Enum.map(entries, &{&1.seq, &1.door, &1.event.name})
  end

  defp delete_prefixed do
    TestRepo.delete_all(from(i in Default.Input, where: like(i.execution_id, "caller-tx-%")))
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, "caller-tx-%")))
  end
end
