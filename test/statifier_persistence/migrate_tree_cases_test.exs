defmodule StatifierPersistence.MigrateTreeCasesTest do
  @moduledoc """
  The case set for `StatifierPersistence.Executions.migrate_tree/4`, run
  against both shipped adapters: the in-memory adapter and the Ecto
  adapter over the Postgres harness (ADR-0005).

  The tree is a library hold and its pickup notice. The hold waits in
  `awaiting_pickup`, and on entering it the hold invoked a durable child:
  a pickup-notice execution that waits in `notice_sent` for the patron's
  acknowledgement. Both documents are edited - the hold's
  `awaiting_pickup` becomes `ready_for_pickup`, and the pickup notice's
  `notice_sent` becomes `patron_notified`.

  Each case names the decision it proves:

    * **Both migrated.** The hold and its pickup notice land on their new
      charts in one call, and the child's linkage pin reads the child's new
      hash (ADR-0015 decisions 1 and 3; ADR-0008's 2026-09-23 Amendment).
    * **A failing child plan refuses the tree.** The pickup notice's plan
      leaves `notice_sent` unmapped; the tree is refused and no node is
      written, the hold included though its own plan applied - every
      node's execution, position and linkage rows read back unchanged
      (ADR-0015 decisions 3 and 4, `on_failure: :refuse`).
    * **A parked parent.** The hold's plan leaves `awaiting_pickup`
      unmapped under `on_failure: :park`; every node the plans name parks
      on the chart it was already on, the notice among them though its own
      plan applied, and an event delivered to the parked hold is refused
      whole - each node's position and linkage rows read back unchanged
      and its execution row changed only in its status (ADR-0015 decision
      4; ADR-0014).
    * **A child absent from the plans.** Only the hold is named; the
      pickup notice keeps its row, its position and its linkage pin, and
      still resolves against its migrated parent: the patron's
      acknowledgement steps it on its old chart and completes the hold on
      the hold's new one (ADR-0015 decision 1; ADR-0013 decision 7).
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, EctoHosts, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Migration.Plan

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

    hold_id = "hold-cases-#{adapter}"

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

  # A driver whose `chart_resolver:` answers every hold chart by hash.
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
  defp waiting_tree!(ctx) do
    hold_driver = driver(ctx, ctx.hold_from)
    {:ok, _execution, _ms} = Driver.create(hold_driver, ctx.hold_id)

    {:ok, _execution, _ms} =
      Driver.send_event(hold_driver, ctx.hold_id, Event.external("copy.available"))

    :ok
  end

  defp plan!(from, to, states) do
    {:ok, plan} = Plan.new(from: hash(from), to: hash(to), states: states)
    plan
  end

  defp hold_plan!(ctx, states \\ %{"awaiting_pickup" => "ready_for_pickup"}),
    do: plan!(ctx.hold_from, ctx.hold_to, states)

  defp notice_plan!(ctx, states \\ %{"notice_sent" => "patron_notified"}),
    do: plan!(ctx.notice_from, ctx.notice_to, states)

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

  # Every stored row of one node, read back from the store: the execution
  # row, the position it holds decoded against `machine`, and the linkage
  # pin under the reserved metadata key (`:no_linkage` for the root).
  defp node_rows(ctx, execution_id, machine) do
    record = stored(ctx, execution_id)
    {:ok, position} = Storage.load_execution_position(ctx.store, execution_id, machine)

    %{
      execution: record,
      position: %{
        blob: record.position_blob,
        leaves: leaves(position),
        invocations: position.active_invocations
      },
      linkage: Linkage.from_metadata(record.metadata)
    }
  end

  # Every node of the tree on the charts it stood on before any call, and
  # the tree as the linkage lists it: the notice under the hold.
  defp tree_rows(ctx) do
    {:ok, children} =
      Storage.list_executions_by_metadata(ctx.store, Linkage.parent_match(ctx.hold_id))

    %{
      hold: node_rows(ctx, ctx.hold_id, ctx.hold_from),
      notice: node_rows(ctx, ctx.notice_id, ctx.notice_from),
      listed: children |> Enum.map(& &1.execution_id) |> Enum.sort()
    }
  end

  defp parked(%{execution: execution} = rows),
    do: %{rows | execution: %{execution | status: :needs_migration}}

  describe "case 1: a parent and one child both migrated" do
    # sabotage: had linkage_pin/3 (executions.ex) answer nil for every
    # node -> red over both adapters: the notice's linkage kept the old
    # notice hash. Verified red, restored from a copy.
    test "the hold and its pickup notice land together, the child's linkage reading its new hash",
         ctx do
      :ok = waiting_tree!(ctx)
      %{notice: %{linkage: {:ok, linkage_before}}} = tree_rows(ctx)

      plans = %{ctx.hold_id => hold_plan!(ctx), ctx.notice_id => notice_plan!(ctx)}

      assert {:ok, [{notice, _notice_facts}, {hold, _hold_facts}]} = migrate_tree(ctx, plans)
      assert notice.execution_id == ctx.notice_id
      assert hold.execution_id == ctx.hold_id

      notice_after = node_rows(ctx, ctx.notice_id, ctx.notice_to)
      assert notice_after.execution.content_hash == hash(ctx.notice_to)
      assert notice_after.execution.status == :active
      assert notice_after.position.leaves == ["patron_notified"]
      assert notice_after.linkage == {:ok, %{linkage_before | content_hash: hash(ctx.notice_to)}}

      hold_after = node_rows(ctx, ctx.hold_id, ctx.hold_to)
      assert hold_after.execution.content_hash == hash(ctx.hold_to)
      assert hold_after.execution.status == :active
      assert hold_after.position.leaves == ["ready_for_pickup"]
      assert Map.values(hold_after.position.invocations) == [linkage_before.invoke_id]
      assert hold_after.linkage == :no_linkage
    end
  end

  describe "case 2: the child's plan fails" do
    # sabotage: had the :refuse clause of decide_tree/7 (executions.ex)
    # write every named node's park through Storage.write_tree_migration/2
    # before answering the same refusal -> red over both adapters: the
    # re-read rows differed from the rows read before the call. Verified
    # red, restored from a copy.
    test "the tree is refused and every row of every node is unchanged", ctx do
      :ok = waiting_tree!(ctx)
      before = tree_rows(ctx)

      # `notice_sent` has no counterpart on the new notice chart.
      plans = %{ctx.hold_id => hold_plan!(ctx), ctx.notice_id => notice_plan!(ctx, %{})}

      assert {:error, {:tree_refused, refusals}} = migrate_tree(ctx, plans)
      assert Map.keys(refusals) == [ctx.notice_id]
      assert {:migration_refused, findings} = refusals[ctx.notice_id]
      assert {:unmapped_state, :configuration, "notice_sent"} in findings

      assert tree_rows(ctx) == before
    end
  end

  describe "case 3: a parked parent" do
    # sabotage: had parks_tree?/1 (executions.ex) answer false for
    # {:migration_refused, _} -> red over both adapters: the answer was
    # {:error, {:tree_refused, _}}, not {:parked, _}. Verified red,
    # restored from a copy.
    test "under on_failure: :park every named node parks where it stood, and the hold refuses a delivery whole",
         ctx do
      :ok = waiting_tree!(ctx)
      before = tree_rows(ctx)

      # `awaiting_pickup` has no counterpart on the new hold chart.
      plans = %{ctx.hold_id => hold_plan!(ctx, %{}), ctx.notice_id => notice_plan!(ctx)}

      assert {:parked, {:tree_refused, refusals}} =
               migrate_tree(ctx, plans, on_failure: :park)

      assert Map.keys(refusals) == [ctx.hold_id]
      assert {:migration_refused, findings} = refusals[ctx.hold_id]
      assert {:unmapped_state, :configuration, "awaiting_pickup"} in findings

      parked_rows = %{before | hold: parked(before.hold), notice: parked(before.notice)}
      assert tree_rows(ctx) == parked_rows

      assert {:error, {:needs_migration, _hold}} =
               Driver.send_event(
                 driver(ctx, ctx.hold_from),
                 ctx.hold_id,
                 Event.external("pickup.expired")
               )

      assert tree_rows(ctx) == parked_rows
    end
  end

  describe "case 4: a child absent from the plans" do
    # sabotage: had unresolved_children/3 (executions.ex) refuse every
    # live node absent from plans whatever its parent's invocations ->
    # red over both adapters: the answer was an {:error, _} refusal, not
    # {:ok, _}. Verified red, restored from a copy.
    test "the pickup notice is left untouched and still resolves against its migrated hold",
         ctx do
      :ok = waiting_tree!(ctx)
      before = tree_rows(ctx)

      assert {:ok, [{hold, _facts}]} = migrate_tree(ctx, %{ctx.hold_id => hold_plan!(ctx)})
      assert hold.content_hash == hash(ctx.hold_to)

      # Untouched: the notice's execution, position and linkage rows.
      assert node_rows(ctx, ctx.notice_id, ctx.notice_from) == before.notice
      assert {:ok, %Linkage{content_hash: pin, invoke_id: invoke_id}} = before.notice.linkage
      assert pin == hash(ctx.notice_from)

      # Still resolving: the migrated hold still holds the invocation the
      # notice's linkage names, and the patron's acknowledgement steps the
      # notice on its old chart and completes the hold on its new one.
      hold_after = node_rows(ctx, ctx.hold_id, ctx.hold_to)
      assert hold_after.position.leaves == ["ready_for_pickup"]
      assert invoke_id in Map.values(hold_after.position.invocations)

      assert {:ok, notice, _ms} =
               Driver.send_event(
                 driver(ctx, ctx.notice_from),
                 ctx.notice_id,
                 Event.external("notice.acknowledged")
               )

      assert notice.status == :completed
      assert notice.content_hash == hash(ctx.notice_from)

      hold_done = stored(ctx, ctx.hold_id)
      assert hold_done.status == :completed
      assert hold_done.content_hash == hash(ctx.hold_to)
    end
  end
end
