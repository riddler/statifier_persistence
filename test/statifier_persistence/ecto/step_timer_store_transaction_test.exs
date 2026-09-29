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
  row still pending. A step whose position save answers an error after
  the executor ran rolls the executor's writes back with it when its lock
  opened the outermost transaction (ADR-0004's 2026-09-28 Amendment);
  inside a caller's transaction it answers the same error and leaves the
  rollback to the caller, and a budget-exhausted step still commits its
  `:failed` record and what its executor wrote.

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
  alias StatifierPersistence.Storage.Ecto, as: EctoStorage
  alias StatifierPersistence.TestRepo

  @timers "sp_test_loan_hold_timers"

  # A host's own serialization strategy that happens to order steps with
  # the Ecto adapter's lock: not the default strategy, so a failed position
  # save commits what the step wrote, as before.
  defmodule HostLockStrategy do
    @behaviour StatifierPersistence.Serialization

    @impl true
    def with_execution(store, execution_id, fun),
      do: EctoStorage.lock_execution(store.opts, execution_id, fun)
  end

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
          <transition event="reported_lost" target="searching">
              <cancel sendid="hold_expiry"/>
          </transition>
      </state>
      <state id="searching">
          <onentry><raise event="shelf_checked"/></onentry>
          <transition event="shelf_checked" target="searching"/>
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

  # sabotage: in Executions' failed_write/2, answered the :update write's
  # error as it is instead of through roll_back/1 -> red on the first
  # assertion after the step: the cancel's removal committed (no pending
  # row). Verified red, restored from a copy.
  test "a step whose position save answers an error rolls back the executor's timer writes",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine, executor())
    assert pending(execution_id) == ["hold_expiry"]
    inputs_before = inputs(execution_id)

    # The cancel's removal runs and returns; then the execution row is
    # gone from under the step, through the same transaction, so the
    # position save that follows the effects answers an error.
    assert {:error, :execution_not_found} =
             step(store, execution_id, machine, "picked_up", executor(remove_on: "loan_started"))

    assert pending(execution_id) == ["hold_expiry"]
    assert executions(execution_id) == 1
    assert leaves(store, execution_id, machine) == ["on_hold"]
    assert inputs(execution_id) == inputs_before

    # Redelivered, the whole step runs again and commits both halves.
    assert {:ok, %{status: :active}, _state} =
             step(store, execution_id, machine, "picked_up", executor())

    assert pending(execution_id) == []
    assert leaves(store, execution_id, machine) == ["on_loan"]
  end

  # sabotage: in Executions' failed_write/2, rolled back every error a
  # step's tail answers (tail_result/6's budget arm included) -> red: the
  # :failed record and the cancel's removal were rolled back with it.
  # Verified red, restored from a copy.
  test "a budget-exhausted step still commits its :failed record and its executor's writes",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} =
      Executions.create(store, execution_id, machine,
        executor: executor(),
        initialize: [max_macrostep_rounds: 5]
      )

    assert pending(execution_id) == ["hold_expiry"]

    assert {:error, {:budget_exhausted, _payload}} =
             step(store, execution_id, machine, "reported_lost", executor())

    assert {:ok, %{status: :failed}} = Storage.fetch_execution(store, execution_id)
    assert pending(execution_id) == []
  end

  # sabotage: in Storage.Ecto's roll_back_if/3, rolled back whether or not
  # the lock opened the outermost transaction -> red: the caller's
  # ROLLBACK TO SAVEPOINT answered an error on a transaction already
  # failed. Verified red, restored from a copy.
  test "inside a caller's transaction a failed position save answers as before and leaves the rollback to the caller",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine, executor())

    assert {:ok, {:error, :execution_not_found}} =
             TestRepo.transaction(fn ->
               TestRepo.query!("SAVEPOINT caller_step")

               answer =
                 step(
                   store,
                   execution_id,
                   machine,
                   "picked_up",
                   executor(remove_on: "loan_started")
                 )

               # The caller undoes the step to its own savepoint and goes on.
               assert {:ok, _result} = TestRepo.query("ROLLBACK TO SAVEPOINT caller_step")

               assert {:ok, _result} =
                        TestRepo.query(
                          "INSERT INTO #{@timers} (execution_id, ordinal, send_id, event) " <>
                            "VALUES ($1, 99, 'renewal_reminder', 'renewal.due')",
                          [execution_id]
                        )

               answer
             end)

    assert pending(execution_id) == ["hold_expiry", "renewal_reminder"]
    assert leaves(store, execution_id, machine) == ["on_hold"]
  end

  # sabotage: in Executions' marked_for/2, passed the roll-back marker to
  # every strategy instead of the default one -> red: under the host's
  # strategy the cancel's removal was rolled back. Verified red, restored
  # from a copy.
  test "under a host's own strategy a failed position save answers as before and commits",
       %{store: store, machine: machine, execution_id: execution_id} do
    {:ok, _execution, _state} = create(store, execution_id, machine, executor())

    assert {:error, :execution_not_found} =
             Executions.step(store, execution_id, machine, Event.external("picked_up"),
               executor: executor(remove_on: "loan_started"),
               serialization: {HostLockStrategy, store}
             )

    assert pending(execution_id) == []
    assert executions(execution_id) == 0
  end

  # The host's executor: a delayed send inserts a row keyed by the send's
  # ordinal, a cancel removes the rows under its send id, both through the
  # step's own repo from the stepping process. `crash_on:` raises on the
  # named <log>, standing in for a crash later in the same step.
  # `remove_on:` deletes the execution's own row on the named <log>, so the
  # position save after the effects matches no row and answers an error.
  defp executor(opts \\ []) do
    crash_on = Keyword.get(opts, :crash_on)
    remove_on = Keyword.get(opts, :remove_on)

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

      {:log, %Log{label: ^remove_on}}, context when is_binary(remove_on) ->
        TestRepo.delete_all(
          from(e in Default.Execution, where: e.execution_id == ^context.execution_id)
        )

        :ok

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

  # The execution's committed input log entries, in order.
  defp inputs(execution_id) do
    TestRepo.all(
      from(i in Default.Input,
        where: i.execution_id == ^execution_id,
        order_by: i.seq,
        select: i.seq
      )
    )
  end

  defp delete_prefixed do
    TestRepo.query!("DELETE FROM #{@timers} WHERE execution_id LIKE 'timer-tx-%'")
    TestRepo.delete_all(from(i in Default.Input, where: like(i.execution_id, "timer-tx-%")))
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, "timer-tx-%")))
  end
end
