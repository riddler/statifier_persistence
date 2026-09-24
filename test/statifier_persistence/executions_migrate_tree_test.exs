defmodule StatifierPersistence.ExecutionsMigrateTreeTest do
  @moduledoc """
  `StatifierPersistence.Executions.migrate_tree/4` (ADR-0015, and the
  linkage pin of ADR-0008's 2026-09-23 Amendment), over both shipped
  adapters.

  The tree is a library hold and its pickup notice. The hold waits in
  `awaiting_pickup`, and on entering it the hold invoked a durable child:
  a pickup-notice execution that waits in `notice_sent` for the patron's
  acknowledgement. Both documents are edited - the hold's
  `awaiting_pickup` becomes `ready_for_pickup`, and the pickup notice's
  `notice_sent` becomes `patron_notified` - and one plan per node moves
  the child first and the hold second, in one store unit, or neither.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, EctoHosts, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.Test.{FailingTreeWriteAdapter, NoChildListingAdapter}

  @hold_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <invoke id="notice" type="library:pickup_notice"/>
        <transition event="done.invoke.notice" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  @hold_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="ready_for_pickup"/>
      </state>
      <state id="ready_for_pickup">
        <invoke id="notice" type="library:pickup_notice"/>
        <transition event="done.invoke.notice" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # The pickup notice: sent to the patron, it waits for the patron's
  # acknowledgement and completes.
  @notice_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="notice_sent">
    <state id="notice_sent">
      <transition event="notice.acknowledged" target="acknowledged"/>
    </state>
    <final id="acknowledged"/>
  </scxml>
  """

  @notice_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="patron_notified">
    <state id="patron_notified">
      <transition event="notice.acknowledged" target="acknowledged"/>
    </state>
    <final id="acknowledged"/>
  </scxml>
  """

  @invoke_types InvokeTypes.new(types: ["library:pickup_notice"])

  @doc false
  def forward(name, _measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, metadata})
    :ok
  end

  setup %{adapter: adapter} do
    machines =
      Map.new([@hold_before, @hold_after, @notice_before, @notice_after], fn source ->
        {:ok, machine} = Statifier.compile(source)
        {source, machine}
      end)

    store = store(adapter)

    for {source, machine} <- machines do
      :ok = Storage.save_chart(store, machine, source)
    end

    # Telemetry handlers are global and the two adapters' cases run
    # together, so the ids name the adapter.
    hold_id = "hold-#{adapter}"

    %{
      store: store,
      hold_id: hold_id,
      notice_id: Linkage.child_execution_id(hold_id, "notice", 0),
      hold_from: machines[@hold_before],
      hold_to: machines[@hold_after],
      notice_from: machines[@notice_before],
      notice_to: machines[@notice_after]
    }
  end

  defp store(:in_memory) do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    store
  end

  defp store(:ecto) do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)
    :ok = Storage.Ecto.isolate(store.opts)
    store
  end

  defp hash(%Machine{identity: identity}), do: identity.content_hash

  # The hold's `<invoke>` starts the pickup notice as a durable child.
  defp notice_dispatch do
    fn "library:pickup_notice", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: @notice_before}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  # A driver whose `chart_resolver:` answers every hold chart by hash, as
  # a host that keeps every saved revision does.
  defp driver(ctx, machine) do
    charts = %{hash(ctx.hold_from) => ctx.hold_from, hash(ctx.hold_to) => ctx.hold_to}

    Driver.new(ctx.store, machine,
      dispatch: notice_dispatch(),
      invoke_types: @invoke_types,
      chart_resolver: &Map.fetch(charts, &1)
    )
  end

  # A hold whose copy is available: it waits in `awaiting_pickup`, and
  # its pickup notice waits in `notice_sent` as a live durable child.
  defp waiting_tree(ctx) do
    hold_driver = driver(ctx, ctx.hold_from)
    {:ok, _execution, _ms} = Driver.create(hold_driver, ctx.hold_id)

    {:ok, _execution, _ms} =
      Driver.send_event(hold_driver, ctx.hold_id, Event.external("copy.available"))

    {stored(ctx, ctx.hold_id), stored(ctx, ctx.notice_id)}
  end

  defp hold_plan!(ctx) do
    {:ok, plan} =
      Plan.new(
        from: hash(ctx.hold_from),
        to: hash(ctx.hold_to),
        states: %{"awaiting_pickup" => "ready_for_pickup"}
      )

    plan
  end

  defp notice_plan!(ctx, states \\ %{"notice_sent" => "patron_notified"}) do
    {:ok, plan} = Plan.new(from: hash(ctx.notice_from), to: hash(ctx.notice_to), states: states)
    plan
  end

  defp plans(ctx, notice_plan \\ nil) do
    %{ctx.hold_id => hold_plan!(ctx), ctx.notice_id => notice_plan || notice_plan!(ctx)}
  end

  defp machines(ctx) do
    Map.new([ctx.hold_from, ctx.hold_to, ctx.notice_from, ctx.notice_to], &{hash(&1), &1})
  end

  defp migrate_tree(ctx, plans, opts \\ []) do
    Executions.migrate_tree(ctx.store, ctx.hold_id, plans, [machines: machines(ctx)] ++ opts)
  end

  defp stored(ctx, execution_id) do
    {:ok, record} = Storage.fetch_execution(ctx.store, execution_id)
    record
  end

  defp leaves(%MachineState{machine: machine} = machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.sort()
  end

  defp attach(event) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, event, &__MODULE__.forward/4, %{pid: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Up to `count` migrated events for either id, in the order they arrived.
  defp migrated_events(ids, count, timeout \\ 500)
  defp migrated_events(_ids, 0, _timeout), do: []

  defp migrated_events({one, other} = ids, count, timeout) do
    receive do
      {:telemetry, [:statifier_persistence, :execution, :migrated], %{execution_id: id} = event}
      when id == one or id == other ->
        [event | migrated_events(ids, count - 1, timeout)]
    after
      timeout -> []
    end
  end

  describe "the hold and its pickup notice moved together" do
    # sabotage: had linkage_pin/3 (executions.ex) answer nil for every
    # node -> red over both adapters: the notice's linkage kept the old
    # notice hash. Verified red, reverted from a copy.
    test "both land on their new charts, the child's linkage reading its new hash", ctx do
      {_hold_before, notice_before} = waiting_tree(ctx)

      assert {:ok, [{notice, notice_facts}, {hold, hold_facts}]} =
               migrate_tree(ctx, plans(ctx))

      assert notice.execution_id == ctx.notice_id
      assert notice.content_hash == hash(ctx.notice_to)
      assert notice_facts.from_content_hash == hash(ctx.notice_from)
      assert hold.execution_id == ctx.hold_id
      assert hold.content_hash == hash(ctx.hold_to)
      assert hold_facts.to_content_hash == hash(ctx.hold_to)

      notice_after = stored(ctx, ctx.notice_id)
      assert notice_after.content_hash == hash(ctx.notice_to)
      assert notice_after.status == :active

      {:ok, linkage_before} = Linkage.from_metadata(notice_before.metadata)
      assert {:ok, linkage} = Linkage.from_metadata(notice_after.metadata)
      assert linkage == %{linkage_before | content_hash: hash(ctx.notice_to)}

      {:ok, notice_state} =
        Storage.load_execution_position(ctx.store, ctx.notice_id, ctx.notice_to)

      assert leaves(notice_state) == ["patron_notified"]

      {:ok, hold_state} = Storage.load_execution_position(ctx.store, ctx.hold_id, ctx.hold_to)
      assert leaves(hold_state) == ["ready_for_pickup"]
      assert Map.values(hold_state.active_invocations) == [linkage.invoke_id]

      # Neither old chart is pinned by this tree any more, by a row or
      # by the child's linkage.
      for old <- [ctx.hold_from, ctx.notice_from] do
        assert {:ok, %{active: 0, needs_migration: 0, children: 0}} =
                 Executions.executions_on(ctx.store, hash(old))
      end

      assert {:ok, %{active: 1, children: 1}} =
               Executions.executions_on(ctx.store, hash(ctx.notice_to))
    end

    # sabotage: had decide_tree/7 (executions.ex) hand the unit the root's
    # re-pin alone (List.last/1 of the writes) -> red over both adapters:
    # the notice's stored hash stayed the old notice chart's, and its step
    # on the new chart did not answer {:ok, _, _}. Verified red, reverted
    # from a copy.
    test "the patron's acknowledgement steps the child on its new chart", ctx do
      waiting_tree(ctx)
      assert {:ok, _moved} = migrate_tree(ctx, plans(ctx))

      notice_driver = driver(ctx, ctx.notice_to)

      assert {:ok, notice, _ms} =
               Driver.send_event(
                 notice_driver,
                 ctx.notice_id,
                 Event.external("notice.acknowledged")
               )

      assert notice.status == :completed
      assert notice.content_hash == hash(ctx.notice_to)

      hold = stored(ctx, ctx.hold_id)
      assert hold.status == :completed
      assert hold.content_hash == hash(ctx.hold_to)
    end

    # sabotage: had tree_migrated/1 (executions.ex) emit the events in
    # reverse (Enum.reverse/1 over moved) -> red over both adapters: the
    # hold's event arrived first. Verified red, reverted from a copy.
    test "one migrated event per node, the child's then the hold's, after the unit", ctx do
      waiting_tree(ctx)
      attach([:statifier_persistence, :execution, :migrated])

      assert {:ok, _moved} = migrate_tree(ctx, plans(ctx))

      notice_id = ctx.notice_id
      hold_id = ctx.hold_id
      notice_to = hash(ctx.notice_to)
      hold_to = hash(ctx.hold_to)

      # Taken in arrival order: the guard matches either node, so the
      # first message the mailbox holds for this tree is the first read.
      assert [first, second] = migrated_events({notice_id, hold_id}, 2)
      assert %{execution_id: ^notice_id, to_content_hash: ^notice_to} = first
      assert %{execution_id: ^hold_id, to_content_hash: ^hold_to} = second
      assert [] = migrated_events({notice_id, hold_id}, 1, 50)
    end
  end

  describe "a refused tree" do
    # sabotage: had migrate_tree_locked/4 (executions.ex) drop the
    # validation refusals and keep only the resolve rule's -> red over
    # both adapters: the command took the clean path and raised a
    # MatchError on the child's {:migration_refused, _}. Verified red,
    # reverted from a copy.
    test "a child whose plan fails refuses the tree with every row unchanged", ctx do
      {hold_before, notice_before} = waiting_tree(ctx)
      attach([:statifier_persistence, :execution, :migrated])

      # `notice_sent` has no counterpart on the new notice chart.
      failing = notice_plan!(ctx, %{})

      assert {:error, {:tree_refused, refusals}} = migrate_tree(ctx, plans(ctx, failing))
      assert [notice_id] = Map.keys(refusals)
      assert notice_id == ctx.notice_id
      assert {:migration_refused, findings} = refusals[ctx.notice_id]
      assert {:unmapped_state, :configuration, "notice_sent"} in findings

      # The hold's own plan applied, and it did not move either.
      assert stored(ctx, ctx.hold_id) == hold_before
      assert stored(ctx, ctx.notice_id) == notice_before

      hold_id = ctx.hold_id
      refute_receive {:telemetry, _event, %{execution_id: ^hold_id}}
      refute_receive {:telemetry, _event, %{execution_id: ^notice_id}}
    end

    # sabotage: had parks_tree?/1 (executions.ex) answer false for
    # {:migration_refused, _} -> red over both adapters: the answer was
    # not {:parked, _}. Verified red, reverted from a copy.
    test "under on_failure: :park every named node parks on its old chart", ctx do
      {hold_before, notice_before} = waiting_tree(ctx)
      failing = notice_plan!(ctx, %{})

      assert {:parked, {:tree_refused, refusals}} =
               migrate_tree(ctx, plans(ctx, failing), on_failure: :park)

      assert {:migration_refused, _findings} = refusals[ctx.notice_id]
      refute Map.has_key?(refusals, ctx.hold_id)

      assert stored(ctx, ctx.hold_id) == %{hold_before | status: :needs_migration}
      assert stored(ctx, ctx.notice_id) == %{notice_before | status: :needs_migration}
    end

    # sabotage: had the in-memory adapter's write_tree_migration/2 keep
    # the executions written before the failing write, and the Ecto
    # adapter's skip tree_rows_stored/2 and return {:error, reason}
    # without rollback/1 -> red over both adapters: the hold's stored
    # record came back changed. Verified red, reverted from the copies.
    #
    # sabotage: had the Ecto adapter's tree_rows_stored/2 answer :ok for
    # every write list, so the missing row is found by its write and
    # rolled back -> red over the Ecto adapter: the answer was the lock's
    # {:adapter, :rollback}, not :execution_not_found. Had the in-memory
    # adapter's tree_write/2 answer another reason -> red over the
    # in-memory adapter. Verified red, reverted from the copies.
    test "a failure inside the one unit writes no node and answers the unit's reason", ctx do
      {hold_before, notice_before} = waiting_tree(ctx)
      failing_store = FailingTreeWriteAdapter.wrap(ctx.store)

      assert {:error, :execution_not_found} =
               Executions.migrate_tree(failing_store, ctx.hold_id, plans(ctx),
                 machines: machines(ctx)
               )

      assert stored(ctx, ctx.hold_id) == hold_before
      assert stored(ctx, ctx.notice_id) == notice_before
    end

    # sabotage: had check_tree_unit/1 (executions.ex) answer :ok for every
    # store -> red over both adapters: the answer was not
    # {:error, :tree_migration_unsupported}. Verified red, reverted from
    # a copy.
    test "an adapter without the unit is refused before any read", ctx do
      {:ok, store} = Storage.new(NoChildListingAdapter, [])

      assert {:error, :tree_migration_unsupported} =
               Executions.migrate_tree(store, ctx.hold_id, plans(ctx), machines: machines(ctx))
    end

    # sabotage: had check_named/2 (executions.ex) answer :ok for every
    # plan set -> red over both adapters: the answer was not the
    # {:not_in_tree, _} refusal. Verified red, reverted from a copy.
    test "an id in plans outside the tree is refused and nothing is written", ctx do
      {hold_before, notice_before} = waiting_tree(ctx)
      outside = "hold-elsewhere-#{ctx.adapter}"

      plans = Map.put(plans(ctx), outside, hold_plan!(ctx))

      assert {:error, {:not_in_tree, [^outside]}} =
               migrate_tree(ctx, plans, on_failure: :park)

      assert stored(ctx, ctx.hold_id) == hold_before
      assert stored(ctx, ctx.notice_id) == notice_before
    end

    # sabotage: had tree_machine/2 (executions.ex) fall back to the first
    # machine in machines: for a missing hash -> red over both adapters:
    # the refusals did not name the missing machine. Verified red,
    # reverted from a copy.
    test "a plan whose machine is missing is refused before any execution is read", ctx do
      {hold_before, notice_before} = waiting_tree(ctx)
      missing = hash(ctx.notice_to)

      assert {:error, {:tree_refused, refusals}} =
               Executions.migrate_tree(ctx.store, ctx.hold_id, plans(ctx),
                 machines: Map.delete(machines(ctx), missing),
                 on_failure: :park
               )

      assert refusals == %{ctx.notice_id => {:machine_missing, missing}}
      assert stored(ctx, ctx.hold_id) == hold_before
      assert stored(ctx, ctx.notice_id) == notice_before
    end

    # A live child the hold never invoked under the id its linkage names:
    # moving the hold alone must not leave it pointing at nothing.
    #
    # sabotage: had unresolved_children/3 (executions.ex) skip every node
    # -> red over both adapters: the answer was not a refused tree.
    # Verified red, reverted from a copy.
    test "a live child absent from plans that would not resolve refuses the tree", ctx do
      {hold_before, _notice_before} = waiting_tree(ctx)
      stray_id = Linkage.child_execution_id(ctx.hold_id, "slip", 0)
      linkage = Linkage.new(ctx.hold_id, "slip", 0, hash(ctx.notice_from))

      {:ok, _execution, _ms} =
        Executions.create(ctx.store, stray_id, ctx.notice_from,
          linkage: linkage,
          executor: fn _effect, _context -> :ok end
        )

      stray_before = stored(ctx, stray_id)

      assert {:error, {:tree_refused, refusals}} =
               migrate_tree(ctx, %{ctx.hold_id => hold_plan!(ctx)})

      assert refusals == %{stray_id => {:child_unresolved, ctx.hold_id, "slip"}}
      assert stored(ctx, ctx.hold_id) == hold_before
      assert stored(ctx, stray_id) == stray_before
    end
  end
end
