defmodule StatifierPersistence.Ecto.RetireChartRaceTest do
  @moduledoc """
  The race ADR-0012 decision 6 names: an execution created on a content
  hash after a retirement's counts were taken and before its tombstone
  is written.

  What closes it is that the tombstone is not an update the counts
  authorise. It is a single conditional `UPDATE` that re-asserts every
  blocking count of decision 1 in its own `WHERE` - no `:active`
  execution row on the hash, no position row on it, no durable-child pin
  naming it, and the row not already retired - so a pin committed before
  that statement runs is in its `NOT EXISTS` and the statement matches
  no row. A statement that matches no row is read back and reported as
  the refusal it is, rather than being taken for a write.

  These cases run live, outside the SQL sandbox, for
  `StatifierPersistence.Ecto.CallerTransactionTest`'s reason: the sandbox
  funnels every caller through one owned connection, so the second
  writer below would be waiting on connection ownership rather than
  committing beside the first. Here the two are real pooled connections
  and the second one's `COMMIT` is one the first can see.

  The conditional `UPDATE` cannot see a write that has read the hash as
  not retired and not yet committed. ADR-0012's 2026-09-28 Amendment
  closes that interleaving with a per-hash advisory lock: a create or a
  migration reads the tombstone under the hash's shared lock inside its
  own transaction, and a retirement takes the exclusive lock as its first
  statement. The cases after the first three race the two on two
  connections, in both orders; the last two show, per ADR-0012's
  2026-09-29 Amendment, that the lock is keyed by the store: two stores
  in one database never wait on each other, and two host modules on one
  charts table do.
  """

  # Its own rows, outside any sandbox: nothing here may run beside
  # another test.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Machine
  alias StatifierPersistence.EctoHosts.{Bigserial, Default, Scoped, SharedIdScoped}
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.TestRepo

  @prefix "retire-race-"

  setup_all do
    Sandbox.mode(TestRepo, :auto)

    # Rows a killed earlier run left behind go first, then this run's own.
    delete_prefixed()

    on_exit(fn ->
      delete_prefixed()
      Sandbox.mode(TestRepo, :manual)
    end)

    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    %{store: store}
  end

  setup do
    %{content_hash: @prefix <> "#{System.unique_integer([:positive])}"}
  end

  # sabotage: in Storage.Ecto.write_tombstone/3, replace
  # unpinned_chart/2 with a query carrying only the content_hash and
  # retired_at clauses (dropping the three NOT EXISTS guards), so the
  # counts taken above it are the only guard -> red, the retirement
  # below tombstoned a chart that had acquired a live execution since
  # those counts were taken, and the last two assertions read nil blobs.
  # Verified red on this file. Reverted from a copy.
  test "an execution committed after the counts refuses the tombstone", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)

    refusal =
      TestRepo.transaction(fn ->
        # The count this caller is deciding on: nothing is running.
        assert {:ok, %{active: 0}} = Executions.executions_on(store, content_hash)

        # A second connection creates one and commits it, which is the
        # arrival the record says must not be retired out from under.
        insert_active_on_another_connection(content_hash)

        Storage.retire_chart(store, content_hash, retired_by: "ops@example.test")
      end)

    assert {:ok, {:error, {:pinned, counts}}} = refusal
    assert counts.executions.active == 1

    # Nothing was written: the bytes the refused retirement would have
    # removed are still readable, and the hash is not tombstoned.
    assert {:ok, chart} = Storage.fetch_chart(store, content_hash)
    assert chart.chart_blob == "chart-bytes"
  end

  # sabotage: in Storage.Ecto.written/4, answer {:ok, ...} for a zero
  # row count instead of reading the store back -> red, the second
  # retirement below reported success over a chart it had not written.
  # Verified red on this file. Reverted from a copy.
  test "a retirement that loses to another retirement reads the winner's tombstone", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)
    first = DateTime.from_naive!(~N[2026-09-19 18:00:00.000000], "Etc/UTC")

    assert {:ok, _retired} =
             Executions.retire_chart(store, content_hash, [],
               retired_by: "first-operator",
               now: first
             )

    assert {:error, {:chart_retired, info}} =
             Executions.retire_chart(store, content_hash, [], retired_by: "second-operator")

    assert info.retired_at == first
    assert info.retired_by == "first-operator"
  end

  # The removal itself, read off the row rather than through a door -
  # every door answers the retired arm for this hash, so this is the
  # only place the bytes can be shown to be gone.
  #
  # sabotage: in Storage.Ecto.write_tombstone/3, drop the two `nil`
  # assignments from the `set:` -> red, the row carried its
  # identity_blob and chart_blob unchanged after the retirement.
  # Verified red on this file. Reverted from a copy.
  test "the tombstoned row keeps its hash and carries no bytes", %{
    store: store,
    content_hash: content_hash
  } do
    save_chart(store, content_hash)

    assert {:ok, _retired} =
             Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

    row = TestRepo.get_by!(Default.Chart, content_hash: content_hash)

    assert row.content_hash == content_hash
    assert row.identity_blob == nil
    assert row.chart_blob == nil
    assert row.retired_by == "ops@example.test"
  end

  # The retirement arrives while a create holds the hash: the create has
  # read the tombstone and is running its effects, its row not yet
  # inserted. The retirement waits for the create's commit and then sees
  # the execution it must not retire out from under.
  #
  # sabotage: in Storage.Ecto.retire_chart/3, drop the exclusive
  # chart_lock/3 call -> red, the retirement answered {:ok, _} while the
  # create was still in its effects instead of waiting. The same case is
  # red when fetch_retired_info/2's shared lock is dropped, and when
  # create_open/4's second read is. Verified red, reverted from a copy.
  test "a retirement that arrives during a create waits for it and refuses as pinned", %{
    store: store
  } do
    {machine, content_hash, source} = loan_chart(store)
    execution_id = @prefix <> "create-first-#{System.unique_integer([:positive])}"
    test_pid = self()

    # Parks on the first effect only; any later one runs straight through.
    in_effects = fn effect, _context ->
      send(test_pid, {:effect, effect})

      if Process.put(:parked, true) == nil do
        send(test_pid, {:in_effects, self()})

        receive do
          :go -> :ok
        end
      end

      :ok
    end

    create =
      Task.async(fn -> Executions.create(store, execution_id, machine, executor: in_effects) end)

    assert_receive {:in_effects, create_pid}, 5_000

    retire =
      Task.async(fn ->
        Storage.retire_chart(store, content_hash, retired_by: "circulation-desk")
      end)

    # Still waiting on the create's shared lock.
    assert Task.yield(retire, 300) == nil

    send(create_pid, :go)
    assert {:ok, _execution, _machine_state} = Task.await(create, 5_000)
    assert {:error, {:pinned, counts}} = Task.await(retire, 5_000)
    assert counts.executions.active == 1

    assert {:ok, chart} = Storage.fetch_chart(store, content_hash)
    assert chart.chart_blob == source
  end

  # The create arrives while a retirement holds the hash, its tombstone
  # written and not yet committed. The create waits for the commit, reads
  # the tombstone, and refuses before any effect.
  #
  # sabotage: in Storage.Ecto.fetch_retired_info/2, drop the shared
  # chart_lock/3 call -> red, the create read the hash as not retired
  # while the tombstone was uncommitted and answered {:ok, _, _} instead
  # of waiting. Red too with retire_chart/3's exclusive lock dropped.
  # Verified red, reverted from a copy.
  test "a create that arrives during a retirement waits for it and answers the retired arm", %{
    store: store
  } do
    {machine, content_hash, _source} = loan_chart(store)
    execution_id = @prefix <> "retire-first-#{System.unique_integer([:positive])}"
    test_pid = self()
    retire = hold_retirement(store, content_hash)
    assert_receive {:retired_uncommitted, retire_pid, {:ok, info}}, 5_000

    recording = fn effect, _context ->
      send(test_pid, {:effect, effect})
      :ok
    end

    create =
      Task.async(fn -> Executions.create(store, execution_id, machine, executor: recording) end)

    # Still waiting on the retirement's exclusive lock.
    assert Task.yield(create, 300) == nil

    send(retire_pid, :commit)
    assert {:ok, ^info} = Task.await(retire, 5_000)
    assert {:error, {:chart_retired, ^info}} = Task.await(create, 5_000)

    refute_received {:effect, _effect}
    assert {:error, :execution_not_found} = Storage.fetch_execution(store, execution_id)
  end

  # The same order for a migration: the `to` hash's retirement holds the
  # lock, and the migration waits, reads the tombstone and re-pins
  # nothing.
  #
  # sabotage: the fetch_retired_info/2 mutation above -> red, the
  # migration answered instead of waiting on the uncommitted tombstone;
  # red too with retire_chart/3's exclusive lock dropped. Verified red,
  # reverted from a copy.
  test "a migration that arrives during the to hash's retirement answers the retired arm", %{
    store: store
  } do
    {from_machine, from_hash, _from_source} = loan_chart(store)
    {to_machine, to_hash, _to_source} = loan_chart(store)
    execution_id = @prefix <> "migrate-#{System.unique_integer([:positive])}"

    assert {:ok, _execution, _machine_state} =
             Executions.create(store, execution_id, from_machine,
               executor: fn _effect, _context -> :ok end
             )

    {:ok, plan} =
      Plan.new(
        from: from_hash,
        to: to_hash,
        states: %{final_id(from_machine) => final_id(to_machine)}
      )

    retire = hold_retirement(store, to_hash)
    assert_receive {:retired_uncommitted, retire_pid, {:ok, info}}, 5_000

    migrate =
      Task.async(fn ->
        Executions.migrate(store, execution_id, plan,
          from_machine: from_machine,
          to_machine: to_machine
        )
      end)

    assert Task.yield(migrate, 300) == nil

    send(retire_pid, :commit)
    assert {:ok, ^info} = Task.await(retire, 5_000)
    assert {:error, {:chart_retired, ^info}} = Task.await(migrate, 5_000)

    assert {:ok, %{content_hash: ^from_hash, status: :active}} =
             Storage.fetch_execution(store, execution_id)
  end

  # The lock's key is the store's (ADR-0012's 2026-09-29 Amendment):
  # `Scoped` and `SharedIdScoped` keep charts in the same table name under
  # two prefixes of one database, so this pair proves the prefix is in the
  # key. The first retirement holds its exclusive lock uncommitted while
  # the second retires the same hash in the other store.
  #
  # sabotage: in Storage.Ecto.chart_lock/3, pass content_hash alone as the
  # second key's text (dropping chart_store(opts)) -> red, the second
  # store's retirement waited on the first store's lock and Task.yield
  # answered nil. Verified red, reverted from a copy.
  test "two stores in one database retire one hash without either waiting", %{
    content_hash: content_hash
  } do
    {:ok, scoped} = Storage.new(Storage.Ecto, persistence: Scoped)
    {:ok, shared_id} = Storage.new(Storage.Ecto, persistence: SharedIdScoped)
    save_chart(scoped, content_hash)
    save_chart(shared_id, content_hash)

    retire = hold_retirement(scoped, content_hash)
    assert_receive {:retired_uncommitted, retire_pid, {:ok, _info}}, 5_000

    other =
      Task.async(fn ->
        Storage.retire_chart(shared_id, content_hash, retired_by: "branch-desk")
      end)

    # Answered while the first store's retirement still holds its lock.
    assert {:ok, {:ok, %{retired_by: "branch-desk"}}} = Task.yield(other, 2_000)

    send(retire_pid, :commit)
    assert {:ok, %{retired_by: "circulation-desk"}} = Task.await(retire, 5_000)
  end

  # Two host modules on one physical table are one store: `Default` and
  # `Bigserial` name the same charts table with no prefix, so a tombstone
  # read through one waits for a retirement through the other and then
  # reads its tombstone. The read is the shared lock's own caller: a
  # plain `SELECT` does not wait on the uncommitted row, so only the
  # advisory lock makes it wait.
  #
  # sabotage: in Storage.Ecto.chart_store/1, append the chart schema's
  # module name to a prefix-free identity (a key per host module rather
  # than per table) -> red, the read did not wait and Task.yield answered
  # {:ok, {:ok, nil}} instead of nil. Verified red, reverted from a copy.
  test "two host modules on one charts table still share the hash's lock", %{
    store: store,
    content_hash: content_hash
  } do
    {:ok, bigserial} = Storage.new(Storage.Ecto, persistence: Bigserial)
    save_chart(store, content_hash)

    retire = hold_retirement(store, content_hash)
    assert_receive {:retired_uncommitted, retire_pid, {:ok, info}}, 5_000

    read =
      Task.async(fn ->
        bigserial.adapter.fetch_retired_info(bigserial.opts, content_hash)
      end)

    # Still waiting on the retirement's exclusive lock.
    assert Task.yield(read, 300) == nil

    send(retire_pid, :commit)
    assert {:ok, ^info} = Task.await(retire, 5_000)
    assert {:ok, ^info} = Task.await(read, 5_000)
  end

  # A library loan chart of its own for each call: the final state's id
  # carries a fresh integer, so its content hash is one no other case
  # shares, and the row is deleted when the case ends.
  defp loan_chart(store) do
    returned = "returned_#{System.unique_integer([:positive])}"

    source = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
            <onentry><log label="loan-opened"/></onentry>
            <transition event="book.returned" target="#{returned}"/>
        </state>
        <final id="#{returned}"/>
    </scxml>
    """

    {:ok, machine} = Statifier.compile(source)
    content_hash = Machine.identity(machine).content_hash
    :ok = Storage.save_chart(store, machine, source)
    on_exit(fn -> delete_hash(content_hash) end)
    {machine, content_hash, source}
  end

  defp final_id(machine) do
    machine.states
    |> Tuple.to_list()
    |> Enum.map(& &1.id)
    |> Enum.find(&(is_binary(&1) and String.starts_with?(&1, "returned_")))
  end

  # A retirement on a connection of its own, its transaction held open
  # after the tombstone is written until the case sends `:commit`.
  defp hold_retirement(store, content_hash) do
    test_pid = self()

    Task.async(fn ->
      {:ok, answer} =
        TestRepo.transaction(fn ->
          answer = Storage.retire_chart(store, content_hash, retired_by: "circulation-desk")
          send(test_pid, {:retired_uncommitted, self(), answer})

          receive do
            :commit -> answer
          end
        end)

      answer
    end)
  end

  defp delete_hash(content_hash) do
    TestRepo.delete_all(from(e in Default.Execution, where: e.content_hash == ^content_hash))
    TestRepo.delete_all(from(c in Default.Chart, where: c.content_hash == ^content_hash))
  end

  defp save_chart(store, content_hash) do
    assert :ok =
             store.adapter.save_chart(store.opts, %{
               content_hash: content_hash,
               identity_blob: "identity-bytes",
               chart_blob: "chart-bytes"
             })
  end

  # A pooled connection of its own, and a commit of its own: this is the
  # writer the retirement has to see, and it has to be a different
  # connection for the seeing to mean anything.
  defp insert_active_on_another_connection(content_hash) do
    Task.async(fn ->
      TestRepo.insert!(%Default.Execution{
        execution_id: @prefix <> "#{System.unique_integer([:positive])}",
        status: "active",
        content_hash: content_hash,
        identity_blob: "identity-bytes",
        position_blob: "position-bytes",
        metadata: %{}
      })
    end)
    |> Task.await()
  end

  defp delete_prefixed do
    TestRepo.delete_all(from(e in Default.Execution, where: like(e.execution_id, ^"#{@prefix}%")))
    TestRepo.delete_all(from(c in Default.Chart, where: like(c.content_hash, ^"#{@prefix}%")))

    for chart <- [Scoped.Chart, SharedIdScoped.Chart] do
      TestRepo.delete_all(from(c in chart, where: like(c.content_hash, ^"#{@prefix}%")))
    end
  end
end
