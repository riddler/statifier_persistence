defmodule StatifierPersistence.ExecutionsMigrateTest do
  @moduledoc """
  `StatifierPersistence.Executions.migrate/4` (ADR-0013 decisions 2 to 9,
  and ADR-0014 decision 1's park), over both shipped adapters.

  The fixture is a library hold. Before the edit it waits in
  `awaiting_pickup`, whose entry schedules the pickup deadline and whose
  `<invoke>` notifies the patron; after it, that state is
  `ready_for_pickup` and the routing step gains a `transferred` outcome.
  Every refusal case re-reads the stored record and compares it whole with
  the one read before the call: a migration either re-pins the execution
  or leaves it as it was, the park's status write the one exception.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{EctoHosts, Execution, Executions, Storage}
  alias StatifierPersistence.Migration.Plan

  @hold_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <datamodel>
      <data id="branch" expr="'central'"/>
    </datamodel>
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="routing"/>
      </state>
      <state id="routing">
        <transition event="copy.routed" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <onentry>
          <send id="pickup" event="pickup.expired" delay="259200s"/>
        </onentry>
        <invoke id="notice" type="library:notify_patron"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  @hold_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <datamodel>
      <data id="branch" expr="'central'"/>
    </datamodel>
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="routing"/>
      </state>
      <state id="routing">
        <transition event="copy.routed" target="ready_for_pickup"/>
        <transition event="copy.transferred" target="transferred"/>
      </state>
      <state id="transferred">
        <transition event="copy.routed" target="ready_for_pickup"/>
      </state>
      <state id="ready_for_pickup">
        <onentry>
          <send id="pickup" event="pickup.expired" delay="259200s"/>
        </onentry>
        <invoke id="notice" type="library:notify_patron"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  @invoke_types InvokeTypes.new(types: ["library:notify_patron"])

  defmodule SpyStrategy do
    @moduledoc false
    # A pass-through serialization strategy whose config is the test pid,
    # so a case can see the strategy it named was the one that ran.
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(test_pid, execution_id, fun) do
      send(test_pid, {:with_execution, execution_id})
      {:ok, fun.()}
    end
  end

  # Module capture rather than an anonymous fun: :telemetry logs a
  # performance warning for a local handler.
  @spec forward([atom()], map(), map(), %{pid: pid()}) :: :ok
  def forward(name, _measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, metadata})
    :ok
  end

  setup %{adapter: adapter} do
    {:ok, from_machine} = Statifier.compile(@hold_before)
    {:ok, to_machine} = Statifier.compile(@hold_after)
    store = store(adapter)
    :ok = Storage.save_chart(store, from_machine, @hold_before)
    :ok = Storage.save_chart(store, to_machine, @hold_after)

    %{
      store: store,
      from_machine: from_machine,
      to_machine: to_machine,
      from_hash: from_machine.identity.content_hash,
      to_hash: to_machine.identity.content_hash
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

  defp quiet(_effect, _context), do: :ok

  defp step_opts, do: [executor: &quiet/2, invoke_types: @invoke_types]

  # A hold whose copy has been routed to the patron's branch: it waits in
  # `awaiting_pickup` with its notice invocation active.
  defp waiting_hold(ctx, execution_id, machine \\ nil) do
    machine = machine || ctx.from_machine

    {:ok, _execution, _ms} =
      Executions.create(ctx.store, execution_id, machine,
        executor: &quiet/2,
        metadata: %{"patron" => "p-17"}
      )

    for name <- ["copy.available", "copy.routed"] do
      {:ok, _execution, _ms} =
        Executions.step(ctx.store, execution_id, machine, Event.external(name), step_opts())
    end

    {:ok, record} = Storage.fetch_execution(ctx.store, execution_id)
    record
  end

  defp plan!(ctx, fields) do
    {:ok, plan} = Plan.new([from: ctx.from_hash, to: ctx.to_hash] ++ fields)
    plan
  end

  defp rename_plan!(ctx, fields \\ []),
    do: plan!(ctx, [states: %{"awaiting_pickup" => "ready_for_pickup"}] ++ fields)

  defp migrate(ctx, execution_id, plan, opts \\ []) do
    Executions.migrate(
      ctx.store,
      execution_id,
      plan,
      [from_machine: ctx.from_machine, to_machine: ctx.to_machine] ++ opts
    )
  end

  defp stored(ctx, execution_id) do
    {:ok, record} = Storage.fetch_execution(ctx.store, execution_id)
    record
  end

  defp attach(event) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, event, &__MODULE__.forward/4, %{pid: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp active_ids(%MachineState{machine: machine, configuration: configuration}) do
    configuration |> Enum.map(&Machine.id(machine, &1)) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  describe "the library hold renamed from awaiting_pickup to ready_for_pickup" do
    # sabotage: made repin/5 write through update_execution_status/4 (status
    # only) instead of update_execution/5 -> red over both adapters: the
    # stored content hash stayed the from hash. Verified red, reverted from
    # a copy.
    test "resumes in the new state on the new hash, counters and ids carried", ctx do
      before = waiting_hold(ctx, "hold-1")
      {:ok, old_state} = Storage.load_execution_position(ctx.store, "hold-1", ctx.from_machine)
      attach([:statifier_persistence, :execution, :migrated])

      plan = rename_plan!(ctx, datamodel: [{:add, "transfer_branch", nil}])

      assert {:ok, %Execution{execution_id: "hold-1", status: :active} = execution, migrated} =
               migrate(ctx, "hold-1", plan)

      assert execution.content_hash == ctx.to_hash

      assert migrated == %{
               from_content_hash: ctx.from_hash,
               to_content_hash: ctx.to_hash,
               dropped: []
             }

      record = stored(ctx, "hold-1")
      assert record.content_hash == ctx.to_hash
      assert record.status == :active
      assert record.metadata == before.metadata

      {:ok, new_state} = Storage.load_execution_position(ctx.store, "hold-1", ctx.to_machine)
      assert active_ids(new_state) == ["hold", "ready_for_pickup"]
      assert new_state.send_counter == old_state.send_counter
      assert new_state.invoke_counter == old_state.invoke_counter
      assert new_state.timer_counter == old_state.timer_counter
      assert Map.values(new_state.active_invocations) == Map.values(old_state.active_invocations)
      assert map_size(new_state.active_invocations) == 1
      assert Map.fetch!(new_state.datamodel, "transfer_branch") == nil
      assert Map.fetch!(new_state.datamodel, "branch") == "central"

      assert {:error, {:identity_mismatch, _stored, _supplied}} =
               Storage.load_execution_position(ctx.store, "hold-1", ctx.from_machine)

      from_hash = ctx.from_hash
      to_hash = ctx.to_hash

      assert_received {:telemetry, [:statifier_persistence, :execution, :migrated],
                       %{
                         execution_id: "hold-1",
                         from_content_hash: ^from_hash,
                         to_content_hash: ^to_hash,
                         dropped: []
                       }}

      assert {:ok, %Execution{status: :completed}, _ms} =
               Executions.step(
                 ctx.store,
                 "hold-1",
                 ctx.to_machine,
                 Event.external("copy.collected"),
                 step_opts()
               )
    end

    # sabotage: made migrate_tail/5's `:needs_migration` fall into the
    # terminal refusal -> red over both adapters: the parked hold was
    # refused instead of migrated. Verified red, reverted from a copy.
    test "a parked hold is migrated by a corrected plan and written back :active", ctx do
      waiting_hold(ctx, "hold-parked")
      :ok = Storage.update_execution_status(ctx.store, "hold-parked", :needs_migration)

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate(ctx, "hold-parked", rename_plan!(ctx))

      assert %{status: :active, content_hash: to_hash} = stored(ctx, "hold-parked")
      assert to_hash == ctx.to_hash
    end

    # sabotage: made migrate/4 go through serialized/5 with entry :step
    # instead of calling the strategy's with_execution/3 -> red over both
    # adapters: a step span opened for the migration. Verified red, reverted
    # from a copy.
    test "runs inside the named serialization strategy and opens no step span", ctx do
      # Telemetry handlers are global and the two adapters' cases run
      # together, so the id names the adapter.
      execution_id = "hold-spy-#{ctx.adapter}"
      waiting_hold(ctx, execution_id)
      attach([:statifier_persistence, :execution, :step, :start])

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate(ctx, execution_id, rename_plan!(ctx), serialization: {SpyStrategy, self()})

      assert_received {:with_execution, ^execution_id}

      refute_received {:telemetry, [:statifier_persistence, :execution, :step, :start],
                       %{execution_id: ^execution_id}}
    end
  end

  describe "a refusal leaves the execution as it was" do
    # sabotage: dropped migrate_tail/5's content-hash clause -> red over both
    # adapters: the load through the guard refused with identity_mismatch
    # instead, so the named refusal never came back. Verified red, reverted
    # from a copy.
    test "a plan whose from is not the execution's hash, under either on_failure", ctx do
      # The hold was created on the to chart, so the plan's from is not its
      # hash.
      before = waiting_hold(ctx, "hold-elsewhere", ctx.to_machine)
      to_hash = ctx.to_hash
      from_hash = ctx.from_hash

      for on_failure <- [:refuse, :park] do
        assert {:error, {:not_on_from_chart, ^to_hash, ^from_hash}} =
                 migrate(ctx, "hold-elsewhere", rename_plan!(ctx), on_failure: on_failure)

        assert stored(ctx, "hold-elsewhere") == before
      end
    end

    # sabotage: made map_set/3 leave an unmapped id out silently -> red over
    # both adapters: the refusal no longer named the unmapped configuration
    # state. Verified red, reverted from a copy.
    test "an unresolved active state is refused with every finding", ctx do
      before = waiting_hold(ctx, "hold-unmapped")

      assert {:error, {:migration_refused, findings}} =
               migrate(ctx, "hold-unmapped", plan!(ctx, []))

      assert {:unmapped_state, :configuration, "awaiting_pickup"} in findings
      assert {:unmapped_state, :entered_states, "awaiting_pickup"} in findings
      assert {:invocation_unmapped, {"awaiting_pickup", 0}} in findings
      assert {:no_pin_source, ["awaiting_pickup"]} in findings
      assert stored(ctx, "hold-unmapped") == before
    end

    # sabotage: made transform/4 export the position with its internal queue
    # emptied -> red over both adapters: the non-quiescent hold migrated.
    # Verified red, reverted from a copy.
    test "a non-quiescent position is refused", ctx do
      waiting_hold(ctx, "hold-busy")

      # The stepper cannot produce a non-quiescent position (it asserts
      # quiescence before every persist), so this one is written through
      # Storage directly.
      {:ok, state} = Storage.load_execution_position(ctx.store, "hold-busy", ctx.from_machine)
      busy = MachineState.enqueue_internal(state, Event.external("copy.collected"))
      :ok = Storage.update_execution(ctx.store, "hold-busy", busy, :active)
      before = stored(ctx, "hold-busy")

      assert {:error, {:migration_refused, [{:not_exportable, :internal_queue_not_empty}]}} =
               migrate(ctx, "hold-busy", rename_plan!(ctx))

      assert stored(ctx, "hold-busy") == before
    end

    # sabotage: made apply_op/2 add a key that is already present -> red over
    # both adapters: the first operation's finding was missing. Verified red,
    # reverted from a copy.
    test "a datamodel operation that does not apply is refused, nothing written", ctx do
      before = waiting_hold(ctx, "hold-datamodel")
      plan = rename_plan!(ctx, datamodel: [{:add, "branch", "east"}, {:remove, "shelf"}])

      assert {:error, {:migration_refused, findings}} = migrate(ctx, "hold-datamodel", plan)

      assert findings == [
               {:datamodel_refused, 0, {:add, "branch", "east"}, :key_present},
               {:datamodel_refused, 1, {:remove, "shelf"}, :key_absent}
             ]

      assert stored(ctx, "hold-datamodel") == before
    end

    # sabotage: made timer_findings/2 answer [] -> red over both adapters: the
    # plan that drops `placed`, a state the hold has left, migrated with no
    # pin source. Verified red, reverted from a copy.
    test "a plan that drops a state is refused without a pin source", ctx do
      before = waiting_hold(ctx, "hold-drop")
      plan = rename_plan!(ctx, drop: ["placed"])

      assert {:error, {:migration_refused, [{:no_pin_source, ["placed"]}]}} =
               migrate(ctx, "hold-drop", plan)

      assert stored(ctx, "hold-drop") == before
    end

    # sabotage: dropped static_check/3 from migrate/4 -> red over both
    # adapters: the unknown target reached the import and the hold was
    # parked. Verified red, reverted from a copy.
    test "a static fault refuses before the execution is read", ctx do
      before = waiting_hold(ctx, "hold-static")
      plan = plan!(ctx, states: %{"awaiting_pickup" => "at_the_desk"})

      assert {:error, {:invalid_plan, [{:unknown_target, :states, "at_the_desk"}]}} =
               migrate(ctx, "hold-static", plan, on_failure: :park)

      assert stored(ctx, "hold-static") == before
    end

    # sabotage: dropped migrate/4's check_chart_retired/2 -> red over both
    # adapters: the hold was re-pinned onto a tombstoned chart. Verified red,
    # reverted from a copy.
    test "a tombstoned to hash is refused, under :park too", ctx do
      before = waiting_hold(ctx, "hold-retired")

      {:ok, _retired} =
        Executions.retire_chart(ctx.store, ctx.to_hash, [], retired_by: "branch-ops")

      assert {:error, {:chart_retired, _info}} =
               migrate(ctx, "hold-retired", rename_plan!(ctx), on_failure: :park)

      assert stored(ctx, "hold-retired") == before
    end

    # sabotage: dropped migrate_tail/5's terminal clause -> red over both
    # adapters: the completed hold was loaded and re-pinned. Verified red,
    # reverted from a copy.
    test "a terminal execution is refused, under :park too", ctx do
      waiting_hold(ctx, "hold-done")

      {:ok, _execution, _ms} =
        Executions.step(
          ctx.store,
          "hold-done",
          ctx.from_machine,
          Event.external("copy.collected"),
          step_opts()
        )

      before = stored(ctx, "hold-done")

      assert {:error, {:terminal_execution, %Execution{status: :completed}}} =
               migrate(ctx, "hold-done", rename_plan!(ctx), on_failure: :park)

      assert stored(ctx, "hold-done") == before
    end
  end

  describe "on_failure: :park" do
    # sabotage: made refuse/4's :park clause return the refusal without the
    # status write -> red over both adapters: the hold stayed :active.
    # Verified red, reverted from a copy.
    test "leaves the execution :needs_migration on its own chart, nothing else written", ctx do
      # Telemetry handlers are global and the two adapters' cases run
      # together, so the id names the adapter.
      execution_id = "hold-park-#{ctx.adapter}"
      before = waiting_hold(ctx, execution_id)
      attach([:statifier_persistence, :execution, :migrated])
      attach([:statifier_persistence, :execution, :terminated])

      assert {:parked, {:migration_refused, findings}} =
               migrate(ctx, execution_id, plan!(ctx, []), on_failure: :park)

      assert {:unmapped_state, :configuration, "awaiting_pickup"} in findings
      assert stored(ctx, execution_id) == %{before | status: :needs_migration, failure: nil}
      refute_received {:telemetry, _name, %{execution_id: ^execution_id}}

      assert {:ok, %{needs_migration: 1}} = Executions.executions_on(ctx.store, ctx.from_hash)
    end
  end
end
