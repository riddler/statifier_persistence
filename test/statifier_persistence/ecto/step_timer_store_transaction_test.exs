defmodule StatifierPersistence.Ecto.StepTimerStoreTransactionTest do
  @moduledoc """
  A host executor that keeps its delayed-send rows in its own table on the
  same repo, written from the stepping process, commits those rows in the
  transaction that saves the step's position: the join the README's
  "Committing timer rows with the step's position" section states.

  The timer table is created here and stands in for a host's timer store.
  A crash after the executor has handled a step's cancel (or a create's
  delayed send), and before the position is saved, must leave neither half
  committed: never a saved position past the cancel with the cancelled
  row still pending.

  Live, outside the SQL sandbox, for `CallerTransactionTest`'s reason: the
  sandbox runs the step's `repo.transaction/1` as a savepoint inside the
  test's own transaction, so what "committed" means is only visible on a
  real `BEGIN` / `COMMIT` on a pooled connection.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.{Cancel, Log, SendDelayed}
  alias Statifier.Event
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.TestRepo

  @timers "sp_test_loan_hold_timers"

  # A library hold: placing it arms a delayed expiry, picking the book up
  # cancels that expiry. Each state logs on entry, after the send, so the
  # crashing executor below can crash after the timer write has returned.
  @hold """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_hold">
      <state id="on_hold">
          <onentry>
              <send event="hold.expired" id="hold_expiry" delay="60s"/>
              <log label="hold_placed"/>
          </onentry>
          <transition event="picked_up" target="on_loan">
              <cancel sendid="hold_expiry"/>
          </transition>
          <transition event="hold.expired" target="released"/>
      </state>
      <state id="on_loan">
          <onentry><log label="loan_started"/></onentry>
      </state>
      <final id="released"/>
  </scxml>
  """

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    TestRepo.query!("""
    CREATE TABLE IF NOT EXISTS #{@timers} (
      execution_id text NOT NULL,
      ordinal integer NOT NULL,
      send_id text,
      event text NOT NULL,
      PRIMARY KEY (execution_id, ordinal)
    )
    """)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      TestRepo.query!("DROP TABLE IF EXISTS #{@timers}")
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    {:ok, machine} = Statifier.compile(@hold)
    %{store: store, machine: machine}
  end

  setup do
    %{execution_id: "timer-tx-#{System.unique_integer([:positive])}"}
  end

  # sabotage: in Storage.Ecto.lock_execution/3, ran the body without
  # repo.transaction/1 -> red: the crashed step's cancel stayed committed
  # (no timer row) under a position still on_hold. Also red with the
  # executor's cancel removal run from a Task (another pooled connection,
  # outside the step's transaction). Verified red, reverted.
  test "a crash after a step's cancel leaves the timer row and the position as they were",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine, executor())
    assert pending(execution_id) == ["hold_expiry"]
    assert leaves(store, execution_id, machine) == ["on_hold"]

    # The cancel's removal has run and returned; the crash comes from the
    # next effect of the same step, before the position is written.
    assert_raise RuntimeError, ~r/crashed on loan_started/, fn ->
      step(store, execution_id, machine, "picked_up", executor(crash_on: "loan_started"))
    end

    assert pending(execution_id) == ["hold_expiry"]
    assert leaves(store, execution_id, machine) == ["on_hold"]

    # Re-driven without the crash, the removal and the position commit
    # together: no pending row under a position past the cancel.
    assert {:ok, %{status: :active}, _state} =
             step(store, execution_id, machine, "picked_up", executor())

    assert pending(execution_id) == []
    assert leaves(store, execution_id, machine) == ["on_loan"]
  end

  # sabotage: in the executor below, wrote the delayed-send insert from a
  # Task (another pooled connection, outside the step's transaction) ->
  # red: the crashed create left a pending timer row for an execution that
  # was never saved. Also red with lock_execution/3's body run without
  # repo.transaction/1. Verified red, reverted.
  test "a crash after a create's delayed-send insert leaves neither the row nor the execution",
       %{store: store, machine: machine, execution_id: execution_id} do
    assert_raise RuntimeError, ~r/crashed on hold_placed/, fn ->
      create(store, execution_id, machine, executor(crash_on: "hold_placed"))
    end

    assert pending(execution_id) == []
    assert executions(execution_id) == 0
  end

  # The host's executor: a delayed send inserts a row keyed by the send's
  # ordinal, a cancel removes the rows under its send id, both through the
  # step's own repo from the stepping process. `crash_on:` raises on the
  # named <log>, standing in for a crash later in the same step.
  defp executor(opts \\ []) do
    crash_on = Keyword.get(opts, :crash_on)

    fn
      {:send_delayed, %SendDelayed{} = send}, context ->
        TestRepo.insert_all(
          @timers,
          [
            %{
              execution_id: context.execution_id,
              ordinal: send.ordinal,
              send_id: send.send_id,
              event: send.event
            }
          ],
          on_conflict: :nothing
        )

        :ok

      {:cancel, %Cancel{send_id: send_id}}, context ->
        TestRepo.delete_all(
          from(t in @timers,
            where: t.execution_id == ^context.execution_id and t.send_id == ^send_id
          )
        )

        :ok

      {:log, %Log{label: ^crash_on}}, _context when is_binary(crash_on) ->
        raise "crashed on #{crash_on}"

      _effect, _context ->
        :ok
    end
  end

  defp create(store, execution_id, machine, executor),
    do: Executions.create(store, execution_id, machine, executor: executor)

  defp step(store, execution_id, machine, name, executor),
    do: Executions.step(store, execution_id, machine, Event.external(name), executor: executor)

  # The send ids still pending for the execution, as committed.
  defp pending(execution_id) do
    TestRepo.all(
      from(t in @timers,
        where: t.execution_id == ^execution_id,
        order_by: t.ordinal,
        select: t.send_id
      )
    )
  end

  # The saved position's active leaves, read back through the store.
  defp leaves(store, execution_id, machine) do
    {:ok, machine_state} = Storage.load_execution_position(store, execution_id, machine)

    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  defp executions(execution_id) do
    TestRepo.aggregate(
      from(e in Default.Execution, where: e.execution_id == ^execution_id),
      :count
    )
  end

  defp delete_prefixed do
    TestRepo.query!("DELETE FROM #{@timers} WHERE execution_id LIKE 'timer-tx-%'")
    TestRepo.delete_all(from(i in Default.Input, where: like(i.execution_id, "timer-tx-%")))
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, "timer-tx-%")))
  end
end
