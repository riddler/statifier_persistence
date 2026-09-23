defmodule StatifierPersistence.ExecutionsMigrateChildrenTest do
  @moduledoc """
  A parent with a live durable child, migrated by
  `StatifierPersistence.Executions.migrate/4` (ADR-0013 decision 7), over
  both shipped adapters.

  The fixture is a library hold whose pickup is a durable subchart: while
  the hold waits in `awaiting_pickup`, its `pickup` invocation is a child
  execution of its own, waiting for `copy.collected`. The edit renames the
  state `ready_for_pickup` and puts a patron notice ahead of the pickup
  among its `<invoke>`s, so the pickup's ordinal moves from 0 to 1 and the
  plan names that move in `invocations`.

  A child's linkage pins the child's own chart, and execution metadata is
  write-once, so a migration of the parent rewrites nothing in the child.
  The child reaches its parent by the invocation id alone, and a migration
  carries every invocation id across unchanged or is refused, so the
  parent's own position answers whether the child still resolves: no child
  row is read and no child's lock is taken.
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
        <invoke id="pickup" type="library:pickup"/>
        <transition event="done.invoke.pickup" target="fulfilled"/>
        <transition event="error.communication.invoke.pickup" target="expired"/>
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
        <transition event="copy.transferred" target="transferred"/>
      </state>
      <state id="transferred">
        <transition event="copy.available" target="ready_for_pickup"/>
      </state>
      <state id="ready_for_pickup">
        <invoke id="notice" type="library:notify_patron"/>
        <invoke id="pickup" type="library:pickup"/>
        <transition event="done.invoke.pickup" target="fulfilled"/>
        <transition event="error.communication.invoke.pickup" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # The pickup itself: it waits at the branch desk until the patron
  # collects the copy, and completes with the branch it was collected at.
  @pickup """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_desk">
    <state id="at_desk">
      <transition event="copy.collected" target="collected"/>
    </state>
    <final id="collected">
      <donedata><content expr="'central'"/></donedata>
    </final>
  </scxml>
  """

  @invoke_types InvokeTypes.new(types: ["library:pickup", "library:notify_patron"])

  @parent_id "hold-1"

  setup %{adapter: adapter} do
    {:ok, from_machine} = Statifier.compile(@hold_before)
    {:ok, to_machine} = Statifier.compile(@hold_after)
    {:ok, pickup_machine} = Statifier.compile(@pickup)
    store = store(adapter)
    :ok = Storage.save_chart(store, from_machine, @hold_before)
    :ok = Storage.save_chart(store, to_machine, @hold_after)

    %{
      store: store,
      from_machine: from_machine,
      to_machine: to_machine,
      pickup_machine: pickup_machine,
      from_hash: from_machine.identity.content_hash,
      to_hash: to_machine.identity.content_hash,
      child_id: Linkage.child_execution_id(@parent_id, "pickup", 0)
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

  # A pickup handler shaped like a durable subchart handler: it answers
  # the `<invoke>` it was handed with the pickup chart as its content.
  defp pickup_dispatch do
    fn "library:pickup", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: @pickup}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  # A driver over `machine` whose `chart_resolver:` answers both hold
  # charts by hash, as a host that keeps every saved revision does.
  defp driver(ctx, machine) do
    charts = %{ctx.from_hash => ctx.from_machine, ctx.to_hash => ctx.to_machine}

    Driver.new(ctx.store, machine,
      dispatch: pickup_dispatch(),
      invoke_types: @invoke_types,
      chart_resolver: &Map.fetch(charts, &1)
    )
  end

  # A hold whose copy is available: it waits in `awaiting_pickup` with its
  # pickup running as a live durable child.
  defp waiting_hold(ctx) do
    parent_driver = driver(ctx, ctx.from_machine)
    {:ok, _execution, _ms} = Driver.create(parent_driver, @parent_id)

    {:ok, _execution, _ms} =
      Driver.send_event(parent_driver, @parent_id, Event.external("copy.available"))

    {stored(ctx, @parent_id), stored(ctx, ctx.child_id)}
  end

  defp plan!(ctx, fields) do
    {:ok, plan} = Plan.new([from: ctx.from_hash, to: ctx.to_hash] ++ fields)
    plan
  end

  # The whole plan for the edit: the rename, and the pickup's move from
  # the first `<invoke>` of its state to the second.
  defp moving_plan!(ctx) do
    plan!(ctx,
      states: %{"awaiting_pickup" => "ready_for_pickup"},
      invocations: [{"awaiting_pickup", 0, "ready_for_pickup", 1}]
    )
  end

  defp migrate(ctx, plan, opts \\ []) do
    Executions.migrate(
      ctx.store,
      @parent_id,
      plan,
      [from_machine: ctx.from_machine, to_machine: ctx.to_machine] ++ opts
    )
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

  defp invocations(%MachineState{machine: machine, active_invocations: invocations}) do
    Map.new(invocations, fn {{state_index, ordinal}, invoke_id} ->
      {{Machine.id(machine, state_index), ordinal}, invoke_id}
    end)
  end

  describe "a hold whose pickup is a live durable child" do
    # sabotage: had repin/5 (executions.ex) cancel the parent's children
    # through cascade_cancel/3 with Linkage.parent_match/1 after its write
    # -> red over both adapters: the child's stored record came back
    # :cancelled, not the record read before the call. Verified red,
    # reverted from a copy.
    test "the parent migrates and the child's stored record is unchanged", ctx do
      {_parent_before, child_before} = waiting_hold(ctx)
      assert child_before.status == :active

      assert {:ok, execution, _migrated} = migrate(ctx, moving_plan!(ctx))
      assert execution.content_hash == ctx.to_hash

      assert stored(ctx, ctx.child_id) == child_before

      assert {:ok, %Linkage{} = linkage} = Linkage.from_metadata(child_before.metadata)
      assert linkage.parent_execution_id == @parent_id
      assert linkage.invoke_id == "pickup"
      assert linkage.content_hash == ctx.pickup_machine.identity.content_hash
    end

    # sabotage: had map_invocations/4 (migration/transform.ex) write the
    # moved invocation under the string "moved" instead of its invoke id
    # -> red over both adapters: the migrated parent's pickup key named
    # "moved", and the child's completion was discarded, leaving the
    # parent in ready_for_pickup. Verified red, reverted from a copy.
    test "the migrated parent names the child's invocation at its new key", ctx do
      waiting_hold(ctx)

      assert {:ok, _execution, _migrated} = migrate(ctx, moving_plan!(ctx))

      {:ok, migrated} = Storage.load_execution_position(ctx.store, @parent_id, ctx.to_machine)
      assert leaves(migrated) == ["ready_for_pickup"]
      assert invocations(migrated) == %{{"ready_for_pickup", 1} => "pickup"}
    end

    # sabotage: the same map_invocations/4 mutation as above -> red over
    # both adapters: the parent stayed :active in ready_for_pickup, because
    # the Driver's liveness read found no active invocation named "pickup"
    # and discarded the child's answer. Verified red, reverted from a copy.
    test "the child's completion reaches the migrated parent through the Driver", ctx do
      waiting_hold(ctx)
      assert {:ok, _execution, _migrated} = migrate(ctx, moving_plan!(ctx))

      child_driver = driver(ctx, ctx.pickup_machine)

      assert {:ok, child, _ms} =
               Driver.send_event(child_driver, ctx.child_id, Event.external("copy.collected"))

      assert child.status == :completed
      assert child.content_hash == ctx.pickup_machine.identity.content_hash

      parent = stored(ctx, @parent_id)
      assert parent.status == :completed
      assert parent.content_hash == ctx.to_hash
    end

    # sabotage: had map_invocations/4 (migration/transform.ex) return no
    # findings of its own -> red over both adapters: the answer lost its
    # {:invocation_unmapped, ...} finding (the unmapped state's finding
    # still refused the plan). Verified red, reverted from a copy.
    test "a plan that leaves the child's invocation unresolvable is refused whole", ctx do
      {parent_before, child_before} = waiting_hold(ctx)

      # The rename is missing, so `awaiting_pickup` has no counterpart on
      # the to chart and neither does the pickup invocation under it.
      plan = plan!(ctx, [])

      assert {:error, {:migration_refused, findings}} = migrate(ctx, plan)
      assert {:invocation_unmapped, {"awaiting_pickup", 0}} in findings
      assert {:unmapped_state, :configuration, "awaiting_pickup"} in findings

      assert stored(ctx, @parent_id) == parent_before
      assert stored(ctx, ctx.child_id) == child_before
    end

    # sabotage: had refuse/4's :park clause (executions.ex) also write
    # :needs_migration to the parent's children, listed through
    # Storage.list_executions_by_metadata/3 with Linkage.parent_match/1 ->
    # red over both adapters: the child's stored record came back
    # :needs_migration. Verified red, reverted from a copy.
    test "under on_failure: :park, a finding parks the parent and not the child", ctx do
      {parent_before, child_before} = waiting_hold(ctx)

      assert {:parked, {:migration_refused, findings}} =
               migrate(ctx, plan!(ctx, []), on_failure: :park)

      assert {:invocation_unmapped, {"awaiting_pickup", 0}} in findings

      assert stored(ctx, @parent_id) == %{parent_before | status: :needs_migration}
      assert stored(ctx, ctx.child_id) == child_before
    end
  end
end
