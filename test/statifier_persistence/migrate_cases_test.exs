defmodule StatifierPersistence.MigrateCasesTest do
  @moduledoc """
  The case set for `StatifierPersistence.Executions.migrate/4`, over both
  shipped adapters. Each case names the decision it proves; ADR-0013 is
  the migration plan (with its 2026-09-23 Amendment on timers) and
  ADR-0014 is the parked status.

  The fixture is a library hold. A patron's hold waits in
  `awaiting_pickup` once its copy is routed to the pickup branch: its
  entry schedules the pickup deadline, and it runs two invocations, a
  patron notice and a hold slip for the desk. The next revision of the
  document renames that state `ready_for_pickup` and gives the routing
  step a `transferred` outcome.

  The cases:

  - identity - a plan that maps every state to itself carries the
    position across whole: configuration, invocations, datamodel and
    counters (ADR-0013 decisions 1 and 2).
  - rename - the hold lands in `ready_for_pickup` on the new hash, the
    revision with the `transferred` outcome, its counters and invocation
    ids carried (decisions 1, 2 and 9).
  - drop - a region the plan drops leaves the position, the parallel
    keeping its other region, and the drop is reported as an operator
    exit in the answer and on the `migrated` event, the only record of
    it; nothing is stored as a trace (decision 5).
  - unknown target refused - a plan naming a state the to chart does not
    have is refused before the execution is read (decisions 3 and 4).
  - non-quiescent refused - a position with a queued internal event is
    refused (decision 3).
  - park then corrected plan - a plan that leaves the wait state unmapped
    parks the hold; a delivery while it is parked is refused whole and
    nothing is appended; the corrected plan migrates it; a delivery after
    it leaves the arm is consumed (ADR-0014 decisions 1 to 3).
  - child untouched and still resolves - a live durable child's record is
    not rewritten, and its completion reaches the migrated parent
    (ADR-0013 decision 7).
  - mapped timer kept - a plan that maps the timer's state asks no pin
    source, and the pending deadline's event is handled on the new chart
    (decision 6).
  - unmapped timer refused - a plan that leaves the timer's state unmapped
    is refused without a pin source, and refused with a finding when a
    source counts a pending timer (decision 6 and the Amendment).
  - dropped active leaf refused - a plan that drops the state the hold
    waits in, and not its whole region, leaves `hold` with no active
    child; it is refused as an illegal configuration, nothing written, and
    parks under `:park` (ADR-0013's invocation and legality Amendment,
    finding 3). The drop case above is the legal drop that still migrates.
  - notice moved off the configuration refused - a plan that keeps every
    state and moves the notice onto a state the hold is not in is refused,
    nothing written, and parks under `:park` (the same Amendment, finding
    2).

  And the paths the invocation, history and lock rules add: an invocation
  whose same-ordinal default is out of range, two invocations that would
  coincide, an invocation under a dropped state, a moved invocation named
  in the plan's `invocations`, history values translated through the plan
  (decision 3), a lock that could not be taken (decision 4), and an
  already-parked execution parked again (ADR-0014 decisions 1 and 3).

  Every refusal re-reads the stored execution record - its status, chart,
  position blob and metadata, where a child's linkage lives - and its
  input log, and compares them whole with what was read before the call.
  The in-memory adapter keeps no input log.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Event, Machine, MachineState, Position}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, EctoHosts, Execution, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.Test.{NoLockAdapter, RefusingPinSource, TimerQueuePinSource}

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
        <invoke id="slip" type="library:print_slip"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # The next revision: the rename and the transferred outcome.
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
        <invoke id="slip" type="library:print_slip"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # A revision that keeps every state id and adds a way to cancel a hold
  # waiting at the desk.
  @hold_cancellable """
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
        <invoke id="slip" type="library:print_slip"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
        <transition event="hold.cancelled" target="cancelled"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
    <final id="cancelled"/>
  </scxml>
  """

  # A revision that keeps every state id, adds a way to cancel a hold
  # waiting at the desk, and adds a `stash` beside the wait state whose
  # one `<invoke>` also authors `id="notice"`. A hold never enters it.
  @hold_stash """
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
        <invoke id="slip" type="library:print_slip"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
        <transition event="hold.cancelled" target="cancelled"/>
      </state>
      <state id="stash">
        <invoke id="notice" type="library:notify_patron"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
    <final id="cancelled"/>
  </scxml>
  """

  # A hold waiting at its branch in two regions at once: the patron's
  # notice, and the copy's transit to the branch.
  @two_regions_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <parallel id="hold">
      <state id="notice_region" initial="notice_pending">
        <state id="notice_pending">
          <transition event="patron.notified" target="notice_sent"/>
        </state>
        <state id="notice_sent"/>
      </state>
      <state id="transit_region" initial="in_transit">
        <state id="in_transit">
          <transition event="copy.routed" target="on_shelf"/>
        </state>
        <state id="on_shelf"/>
      </state>
      <transition event="copy.collected" target="fulfilled"/>
    </parallel>
    <final id="fulfilled"/>
  </scxml>
  """

  # Its next revision holds copies at every branch, so the transit region
  # is removed entirely; the parallel keeps the notice region alone.
  @two_regions_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <parallel id="hold">
      <state id="notice_region" initial="notice_pending">
        <state id="notice_pending">
          <transition event="patron.notified" target="notice_sent"/>
        </state>
        <state id="notice_sent"/>
      </state>
      <transition event="copy.collected" target="fulfilled"/>
    </parallel>
    <final id="fulfilled"/>
  </scxml>
  """

  # A revision whose desk no longer prints a hold slip.
  @hold_no_slip """
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

  # A revision that prints the slip before it notifies the patron: the
  # same two `<invoke>` elements, in the other order.
  @hold_slip_first """
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
      </state>
      <state id="ready_for_pickup">
        <onentry>
          <send id="pickup" event="pickup.expired" delay="259200s"/>
        </onentry>
        <invoke id="slip" type="library:print_slip"/>
        <invoke id="notice" type="library:notify_patron"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # A hold that a branch closure suspends: the history state remembers
  # where the hold was, and the reopening resumes it there.
  @suspendable_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <history id="hold_history" type="shallow">
        <transition target="placed"/>
      </history>
      <transition event="branch.closed" target="suspended"/>
      <state id="placed">
        <transition event="copy.available" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <transition event="copy.collected" target="fulfilled"/>
      </state>
    </state>
    <state id="suspended">
      <transition event="branch.reopened" target="hold_history"/>
    </state>
    <final id="fulfilled"/>
  </scxml>
  """

  # Its next revision renames the wait state and the history state.
  @suspendable_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <history id="resume_point" type="shallow">
        <transition target="placed"/>
      </history>
      <transition event="branch.closed" target="suspended"/>
      <state id="placed">
        <transition event="copy.available" target="ready_for_pickup"/>
      </state>
      <state id="ready_for_pickup">
        <transition event="copy.collected" target="fulfilled"/>
      </state>
    </state>
    <state id="suspended">
      <transition event="branch.reopened" target="resume_point"/>
    </state>
    <final id="fulfilled"/>
  </scxml>
  """

  # A hold whose pickup is a durable subchart, and its renamed revision.
  @desk_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <invoke id="pickup" type="library:pickup"/>
        <transition event="done.invoke.pickup" target="fulfilled"/>
      </state>
    </state>
    <final id="fulfilled"/>
  </scxml>
  """

  @desk_after """
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
        <invoke id="pickup" type="library:pickup"/>
        <transition event="done.invoke.pickup" target="fulfilled"/>
      </state>
    </state>
    <final id="fulfilled"/>
  </scxml>
  """

  # The pickup itself: it waits at the desk until the patron collects the
  # copy.
  @pickup """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_desk">
    <state id="at_desk">
      <transition event="copy.collected" target="collected"/>
    </state>
    <final id="collected"/>
  </scxml>
  """

  @invoke_types InvokeTypes.new(
                  types: ["library:notify_patron", "library:print_slip", "library:pickup"]
                )

  defmodule QuietTimerQueue do
    @moduledoc false
    # A timer queue with nothing pending for any execution.
    @behaviour StatifierPersistence.PinSource

    @impl StatifierPersistence.PinSource
    def pins(_content_hash, _context), do: %{pending_timers: 0}
  end

  defmodule NoLockEcto do
    @moduledoc false
    # The Ecto adapter without its optional lock_execution/3, over the
    # same opts: the default serialization strategy cannot take a lock
    # through it. The in-memory counterpart is NoLockAdapter.
    @behaviour StatifierPersistence.Storage.Adapter

    alias StatifierPersistence.Storage.Ecto, as: EctoAdapter

    @impl true
    defdelegate init(opts), to: EctoAdapter

    @impl true
    defdelegate save_chart(opts, chart_record), to: EctoAdapter

    @impl true
    defdelegate fetch_chart(opts, content_hash), to: EctoAdapter

    @impl true
    defdelegate save_position(opts, position_record), to: EctoAdapter

    @impl true
    defdelegate fetch_position(opts, session_id), to: EctoAdapter

    @impl true
    defdelegate insert_execution(opts, execution_record), to: EctoAdapter

    @impl true
    defdelegate fetch_execution(opts, execution_id), to: EctoAdapter

    @impl true
    defdelegate update_execution(opts, execution_record), to: EctoAdapter
  end

  # Module capture rather than an anonymous fun: :telemetry logs a
  # performance warning for a local handler.
  @spec forward([atom()], map(), map(), %{pid: pid()}) :: :ok
  def forward(name, _measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, metadata})
    :ok
  end

  setup %{adapter: adapter} do
    store = store(adapter)

    machines =
      Map.new(
        [
          before: @hold_before,
          after: @hold_after,
          cancellable: @hold_cancellable,
          stash: @hold_stash,
          two_regions_before: @two_regions_before,
          two_regions_after: @two_regions_after,
          no_slip: @hold_no_slip,
          slip_first: @hold_slip_first,
          suspendable_before: @suspendable_before,
          suspendable_after: @suspendable_after,
          desk_before: @desk_before,
          desk_after: @desk_after,
          pickup: @pickup
        ],
        fn {name, source} ->
          {:ok, machine} = Statifier.compile(source)
          :ok = Storage.save_chart(store, machine, source)
          {name, machine}
        end
      )

    %{store: store, machines: machines}
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

  defp no_lock(%Storage{adapter: Storage.InMemory} = store), do: %{store | adapter: NoLockAdapter}
  defp no_lock(%Storage{adapter: Storage.Ecto} = store), do: %{store | adapter: NoLockEcto}

  defp quiet(_effect, _context), do: :ok

  defp step_opts, do: [executor: &quiet/2, invoke_types: @invoke_types]

  defp machine(ctx, name), do: Map.fetch!(ctx.machines, name)
  defp hash(ctx, name), do: machine(ctx, name).identity.content_hash

  defp drive(ctx, execution_id, machine_name, events) do
    machine = machine(ctx, machine_name)
    {:ok, _execution, _ms} = Executions.create(ctx.store, execution_id, machine, step_opts())

    for name <- events do
      {:ok, _execution, _ms} =
        Executions.step(ctx.store, execution_id, machine, Event.external(name), step_opts())
    end

    snapshot(ctx, execution_id)
  end

  # A hold whose copy has been routed to its branch: it waits in
  # `awaiting_pickup` with its notice and slip invocations active and its
  # pickup deadline pending.
  defp waiting_hold(ctx, execution_id),
    do: drive(ctx, execution_id, :before, ["copy.available", "copy.routed"])

  # A hold whose copy is on its way to the branch: it waits in `routing`,
  # before `awaiting_pickup` has scheduled anything for it.
  defp routing_hold(ctx, execution_id), do: drive(ctx, execution_id, :before, ["copy.available"])

  defp plan!(ctx, to, fields \\ []) do
    {:ok, plan} = Plan.new([from: hash(ctx, :before), to: hash(ctx, to)] ++ fields)
    plan
  end

  defp rename(fields \\ []), do: [states: %{"awaiting_pickup" => "ready_for_pickup"}] ++ fields

  defp migrate(ctx, execution_id, plan, to, opts \\ []) do
    migrate_on(ctx.store, execution_id, plan, machine(ctx, :before), machine(ctx, to), opts)
  end

  defp migrate_on(store, execution_id, plan, from_machine, to_machine, opts) do
    Executions.migrate(
      store,
      execution_id,
      plan,
      [from_machine: from_machine, to_machine: to_machine] ++ opts
    )
  end

  defp step(ctx, execution_id, machine_name, event_name) do
    Executions.step(
      ctx.store,
      execution_id,
      machine(ctx, machine_name),
      Event.external(event_name),
      step_opts()
    )
  end

  # The execution record - status, chart, identity, position blob and
  # metadata, which is where a child's linkage lives - and the input log.
  defp snapshot(ctx, execution_id) do
    {:ok, record} = Storage.fetch_execution(ctx.store, execution_id)
    %{record: record, inputs: inputs(ctx, execution_id)}
  end

  defp inputs(ctx, execution_id) do
    case Executions.inputs(ctx.store, execution_id) do
      :not_supported -> :not_supported
      {:ok, entries} -> entries
    end
  end

  defp parked(%{record: record} = snapshot),
    do: %{snapshot | record: %{record | status: :needs_migration, failure: nil}}

  defp exported(ctx, execution_id, machine_name) do
    {:ok, machine_state} =
      Storage.load_execution_position(ctx.store, execution_id, machine(ctx, machine_name))

    {:ok, exported} = Position.export(machine_state)
    exported
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

  # A driver over the desk charts whose pickup handler starts the pickup
  # as a durable child, and whose `chart_resolver:` answers every desk
  # chart by hash, as a host that keeps every saved revision does.
  defp desk_driver(ctx, machine_name) do
    charts =
      Map.new([:desk_before, :desk_after, :pickup], fn name ->
        {hash(ctx, name), machine(ctx, name)}
      end)

    dispatch = fn "library:pickup", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: @pickup}
      {:start_child, resolved, {:invoke, resolved}}
    end

    Driver.new(ctx.store, machine(ctx, machine_name),
      dispatch: dispatch,
      invoke_types: @invoke_types,
      chart_resolver: &Map.fetch(charts, &1)
    )
  end

  describe "the nine cases" do
    # sabotage: had transform_export/5 (migration/transform.ex) write
    # `active_invocations: %{}` into the export it imports -> red over both
    # adapters: the migrated hold had no invocations. Verified red,
    # reverted from a copy.
    test "identity: a plan mapping every state to itself carries the position whole", ctx do
      waiting_hold(ctx, "hold-same")
      before = exported(ctx, "hold-same", :before)

      every_state =
        Map.new(
          ~w(hold placed routing awaiting_pickup fulfilled expired),
          &{&1, &1}
        )

      plan = plan!(ctx, :cancellable, states: every_state)

      assert {:ok, %Execution{status: :active} = execution, %{dropped: []}} =
               migrate(ctx, "hold-same", plan, :cancellable)

      assert execution.content_hash == hash(ctx, :cancellable)

      # The export names the chart it was read from; everything else in it
      # crosses unchanged.
      migrated = exported(ctx, "hold-same", :cancellable)
      assert migrated.identity.content_hash == hash(ctx, :cancellable)
      assert Map.delete(migrated, :identity) == Map.delete(before, :identity)

      assert {:ok, %Execution{status: :completed}, _ms} =
               step(ctx, "hold-same", :cancellable, "hold.cancelled")
    end

    # sabotage: deleted map_state/4's plan-mapping clause
    # (migration/transform.ex) -> red over both adapters: awaiting_pickup
    # came back unmapped and the rename was refused. Verified red, reverted
    # from a copy.
    test "rename: the hold lands in ready_for_pickup on the new hash", ctx do
      waiting_hold(ctx, "hold-renamed")
      before = exported(ctx, "hold-renamed", :before)

      assert {:ok, %Execution{status: :active} = execution, %{dropped: []}} =
               migrate(ctx, "hold-renamed", plan!(ctx, :after, rename()), :after)

      assert execution.content_hash == hash(ctx, :after)

      {:ok, state} =
        Storage.load_execution_position(ctx.store, "hold-renamed", machine(ctx, :after))

      assert leaves(state) == ["ready_for_pickup"]

      after_export = exported(ctx, "hold-renamed", :after)
      assert after_export.send_counter == before.send_counter
      assert after_export.invoke_counter == before.invoke_counter
      assert after_export.timer_counter == before.timer_counter

      assert after_export.active_invocations == %{
               {"ready_for_pickup", 0} => before.active_invocations[{"awaiting_pickup", 0}],
               {"ready_for_pickup", 1} => before.active_invocations[{"awaiting_pickup", 1}]
             }

      assert {:ok, %Execution{status: :completed}, _ms} =
               step(ctx, "hold-renamed", :after, "copy.collected")
    end

    # sabotage: had dropped/2 (migration/transform.ex) answer [] -> red over
    # both adapters: the answer's dropped list was empty. Verified red,
    # reverted from a copy. And: had configuration_findings/2 refuse every
    # configuration -> red over both adapters: the legal region drop was
    # refused as an illegal configuration. Verified red, reverted from a
    # copy.
    test "drop: a dropped region leaves the position, reported as an operator exit", ctx do
      execution_id = "hold-dropped-#{ctx.adapter}"
      before = drive(ctx, execution_id, :two_regions_before, [])
      attach([:statifier_persistence, :execution, :migrated])

      {:ok, plan} =
        Plan.new(
          from: hash(ctx, :two_regions_before),
          to: hash(ctx, :two_regions_after),
          drop: ["transit_region", "in_transit", "on_shelf"]
        )

      assert {:ok, %Execution{status: :active}, %{dropped: ["in_transit", "transit_region"]}} =
               migrate_on(
                 ctx.store,
                 execution_id,
                 plan,
                 machine(ctx, :two_regions_before),
                 machine(ctx, :two_regions_after),
                 []
               )

      assert_received {:telemetry, [:statifier_persistence, :execution, :migrated],
                       %{execution_id: ^execution_id, dropped: ["in_transit", "transit_region"]}}

      exported = exported(ctx, execution_id, :two_regions_after)

      for id <- ["transit_region", "in_transit", "on_shelf"] do
        refute MapSet.member?(exported.configuration, id)
        refute MapSet.member?(exported.entered_states, id)
      end

      # On the to chart `hold` is a parallel whose one region is
      # `notice_region`, so the parallel, that region and its active leaf
      # are a whole configuration of it.
      assert exported.configuration == MapSet.new(["hold", "notice_region", "notice_pending"])

      # A drop delivers no event, so nothing is appended to the input log.
      assert snapshot(ctx, execution_id).inputs == before.inputs

      assert {:ok, %Execution{status: :active}, _ms} =
               step(ctx, execution_id, :two_regions_after, "patron.notified")
    end

    # sabotage: dropped migrate/4's static_check/3 -> red over both
    # adapters: the unknown target reached the transform, which raised a
    # MatchError on it. Verified red, reverted from a copy.
    test "an unknown target is refused, nothing written", ctx do
      before = waiting_hold(ctx, "hold-unknown")
      plan = plan!(ctx, :after, states: %{"awaiting_pickup" => "at_the_desk"})

      for on_failure <- [:refuse, :park] do
        assert {:error, {:invalid_plan, [{:unknown_target, :states, "at_the_desk"}]}} =
                 migrate(ctx, "hold-unknown", plan, :after, on_failure: on_failure)

        assert snapshot(ctx, "hold-unknown") == before
      end
    end

    # sabotage: had transform/5 (migration/transform.ex) export the
    # position with its internal queue emptied -> red over both adapters:
    # the non-quiescent hold migrated. Verified red, reverted from a copy.
    test "a non-quiescent position is refused, nothing written", ctx do
      waiting_hold(ctx, "hold-busy")

      # The stepper cannot persist a non-quiescent position, so this one is
      # written through Storage directly.
      {:ok, state} =
        Storage.load_execution_position(ctx.store, "hold-busy", machine(ctx, :before))

      busy = MachineState.enqueue_internal(state, Event.external("copy.collected"))
      :ok = Storage.update_execution(ctx.store, "hold-busy", busy, :active)
      before = snapshot(ctx, "hold-busy")

      assert {:error, {:migration_refused, [{:not_exportable, :internal_queue_not_empty}]}} =
               migrate(ctx, "hold-busy", plan!(ctx, :after, rename()), :after)

      assert snapshot(ctx, "hold-busy") == before
    end

    # sabotage: deleted step_tail/7's :needs_migration refusal arm
    # (executions.ex) -> red over both adapters: the delivery to the parked
    # hold was loaded and stepped. Verified red, reverted from a copy.
    test "park then a corrected plan: a delivery while parked is refused, one after is consumed",
         ctx do
      before = waiting_hold(ctx, "hold-parked")

      # The first plan leaves the wait state unmapped; the host's queue
      # answers for its timer, so the refusal is a finding and parks.
      assert {:parked, {:migration_refused, findings}} =
               migrate(ctx, "hold-parked", plan!(ctx, :after), :after,
                 on_failure: :park,
                 pin_sources: [QuietTimerQueue]
               )

      assert {:unmapped_state, :configuration, "awaiting_pickup"} in findings
      assert snapshot(ctx, "hold-parked") == parked(before)

      assert {:error, {:needs_migration, %Execution{status: :needs_migration}}} =
               step(ctx, "hold-parked", :before, "copy.collected")

      assert snapshot(ctx, "hold-parked") == parked(before)

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate(ctx, "hold-parked", plan!(ctx, :after, rename()), :after)

      assert {:ok, %Execution{status: :completed}, _ms} =
               step(ctx, "hold-parked", :after, "copy.collected")

      case {before.inputs, snapshot(ctx, "hold-parked").inputs} do
        {:not_supported, :not_supported} ->
          :ok

        {logged, now} ->
          assert length(now) == length(logged) + 1
          assert List.last(now).event.name == "copy.collected"
      end
    end

    # sabotage: had map_invocations/4 (migration/transform.ex) carry every
    # invocation across under the id "moved" -> red over both adapters: the
    # child's completion was discarded and the parent never completed.
    # Verified red, reverted from a copy.
    test "child untouched: the live child's record is unchanged and still reaches the parent",
         ctx do
      parent_driver = desk_driver(ctx, :desk_before)
      {:ok, _execution, _ms} = Driver.create(parent_driver, "hold-desk")

      {:ok, _execution, _ms} =
        Driver.send_event(parent_driver, "hold-desk", Event.external("copy.available"))

      child_id = Linkage.child_execution_id("hold-desk", "pickup", 0)
      child_before = snapshot(ctx, child_id)
      assert child_before.record.status == :active

      {:ok, plan} =
        Plan.new(
          from: hash(ctx, :desk_before),
          to: hash(ctx, :desk_after),
          states: %{"awaiting_pickup" => "ready_for_pickup"}
        )

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate_on(
                 ctx.store,
                 "hold-desk",
                 plan,
                 machine(ctx, :desk_before),
                 machine(ctx, :desk_after),
                 []
               )

      assert snapshot(ctx, child_id) == child_before

      assert {:ok, %Linkage{parent_execution_id: "hold-desk", invoke_id: "pickup"}} =
               Linkage.from_metadata(child_before.record.metadata)

      assert {:ok, %Execution{status: :completed}, _ms} =
               Driver.send_event(
                 desk_driver(ctx, :pickup),
                 child_id,
                 Event.external("copy.collected")
               )

      assert %{record: %{status: :completed, content_hash: parent_hash}} =
               snapshot(ctx, "hold-desk")

      assert parent_hash == hash(ctx, :desk_after)
    end

    # sabotage: had timer_check/4 (executions.ex) answer {:ask, sources}
    # for a plan that maps every timer-owning state -> red over both
    # adapters: the raising source was asked and refused the rename.
    # Verified red, reverted from a copy.
    test "mapped timer kept: no source is asked, and the deadline is handled on the new chart",
         ctx do
      waiting_hold(ctx, "hold-kept")

      assert {:ok, %Execution{status: :active}, %{dropped: []}} =
               migrate(ctx, "hold-kept", plan!(ctx, :after, rename()), :after,
                 pin_sources: [RefusingPinSource]
               )

      # `ready_for_pickup` handles the deadline's event.
      assert {:ok, %Execution{status: :completed}, _ms} =
               step(ctx, "hold-kept", :after, "pickup.expired")
    end

    # sabotage: had pending_timer_findings/4 (migration/transform.ex)
    # answer [] -> red over both adapters: the hold migrated with
    # awaiting_pickup unmapped while the queue counted a pending timer.
    # Verified red, reverted from a copy.
    test "unmapped timer refused: without a source, and with a counted timer", ctx do
      before = routing_hold(ctx, "hold-unmapped-timer")
      plan = plan!(ctx, :after)

      assert {:error, {:no_pin_source, ["awaiting_pickup"]}} =
               migrate(ctx, "hold-unmapped-timer", plan, :after, on_failure: :park)

      assert snapshot(ctx, "hold-unmapped-timer") == before

      assert {:error,
              {:migration_refused,
               [
                 {:pending_timers, ["awaiting_pickup"],
                  %{TimerQueuePinSource => %{pending_timers: 1}}}
               ]}} =
               migrate(ctx, "hold-unmapped-timer", plan, :after,
                 pin_sources: [TimerQueuePinSource]
               )

      assert snapshot(ctx, "hold-unmapped-timer") == before
    end
  end

  describe "invocations, history and the lock" do
    # sabotage: had default_invocation/4 (migration/transform.ex) accept
    # any ordinal -> red over both adapters: the slip's invocation was
    # imported at an ordinal the to state does not have. Verified red,
    # reverted from a copy.
    test "an invocation whose same-ordinal default is out of range is refused", ctx do
      before = waiting_hold(ctx, "hold-no-slip")

      assert {:error, {:migration_refused, findings}} =
               migrate(ctx, "hold-no-slip", plan!(ctx, :no_slip, rename()), :no_slip)

      assert findings == [
               {:invocation_out_of_range, {"awaiting_pickup", 1}, {"ready_for_pickup", 1}, 1}
             ]

      assert snapshot(ctx, "hold-no-slip") == before
    end

    # sabotage: had coinciding/1 (migration/transform.ex) answer [] -> red
    # over both adapters: one invocation overwrote the other and the hold
    # migrated. Verified red, reverted from a copy.
    test "two invocations that would share a key are refused", ctx do
      before = waiting_hold(ctx, "hold-coincide")
      # The notice is moved onto the slip's key, and the slip keeps its
      # ordinal by default.
      plan =
        plan!(ctx, :after, rename(invocations: [{"awaiting_pickup", 0, "ready_for_pickup", 1}]))

      assert {:error, {:migration_refused, findings}} =
               migrate(ctx, "hold-coincide", plan, :after)

      assert findings == [
               {:invocations_coincide, {"ready_for_pickup", 1},
                [{"awaiting_pickup", 0}, {"awaiting_pickup", 1}]}
             ]

      assert snapshot(ctx, "hold-coincide") == before
    end

    # sabotage: had default_invocation/4's :dropped clause
    # (migration/transform.ex) keep the key -> red over both adapters: the
    # findings named the import's refusal and no :invocation_dropped.
    # Verified red, reverted from a copy.
    test "an invocation under a dropped state is refused", ctx do
      before = waiting_hold(ctx, "hold-dropped-invocation")
      plan = plan!(ctx, :after, drop: ["awaiting_pickup"])

      assert {:error, {:migration_refused, findings}} =
               migrate(ctx, "hold-dropped-invocation", plan, :after,
                 pin_sources: [QuietTimerQueue]
               )

      # Dropping the active leaf leaves a configuration this case does not
      # judge, so it asserts only the two invocation findings.
      assert {:invocation_dropped, {"awaiting_pickup", 0}} in findings
      assert {:invocation_dropped, {"awaiting_pickup", 1}} in findings

      assert snapshot(ctx, "hold-dropped-invocation") == before
    end

    # sabotage: had map_invocation/4 (migration/transform.ex) ignore the
    # plan's invocations -> red over both adapters: each invocation id
    # stayed at its old ordinal, on the other element. Verified red,
    # reverted from a copy.
    test "a moved invocation named in the plan lands on the same element", ctx do
      waiting_hold(ctx, "hold-reordered")
      before = exported(ctx, "hold-reordered", :before)

      plan =
        plan!(
          ctx,
          :slip_first,
          rename(
            invocations: [
              {"awaiting_pickup", 0, "ready_for_pickup", 1},
              {"awaiting_pickup", 1, "ready_for_pickup", 0}
            ]
          )
        )

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate(ctx, "hold-reordered", plan, :slip_first)

      # In the to chart the slip is the first `<invoke>` and the notice the
      # second.
      assert exported(ctx, "hold-reordered", :slip_first).active_invocations == %{
               {"ready_for_pickup", 0} => before.active_invocations[{"awaiting_pickup", 1}],
               {"ready_for_pickup", 1} => before.active_invocations[{"awaiting_pickup", 0}]
             }
    end

    # sabotage: had map_history_values/2 (migration/transform.ex) keep the
    # recorded ids untranslated -> red over both adapters: the import
    # refused the from chart's awaiting_pickup. Verified red, reverted from
    # a copy.
    test "history values are translated through the plan", ctx do
      drive(ctx, "hold-suspended", :suspendable_before, [
        "copy.available",
        "branch.closed"
      ])

      {:ok, plan} =
        Plan.new(
          from: hash(ctx, :suspendable_before),
          to: hash(ctx, :suspendable_after),
          states: %{"awaiting_pickup" => "ready_for_pickup"},
          history: %{"hold_history" => "resume_point"}
        )

      assert {:ok, %Execution{status: :active}, _migrated} =
               migrate_on(
                 ctx.store,
                 "hold-suspended",
                 plan,
                 machine(ctx, :suspendable_before),
                 machine(ctx, :suspendable_after),
                 []
               )

      assert exported(ctx, "hold-suspended", :suspendable_after).history_values == %{
               "resume_point" => MapSet.new(["ready_for_pickup"])
             }

      assert {:ok, %Execution{status: :active}, state} =
               step(ctx, "hold-suspended", :suspendable_after, "branch.reopened")

      assert leaves(state) == ["ready_for_pickup"]
    end

    # sabotage: had AdapterLock.with_execution/3 run the function unlocked
    # when the adapter exports no lock -> red over both adapters: the hold
    # migrated. Verified red, reverted from a copy.
    test "a lock that could not be taken is refused, nothing written", ctx do
      before = waiting_hold(ctx, "hold-unlocked")

      for on_failure <- [:refuse, :park] do
        assert {:error, {:serialization, :not_supported}} =
                 migrate_on(
                   no_lock(ctx.store),
                   "hold-unlocked",
                   plan!(ctx, :after, rename()),
                   machine(ctx, :before),
                   machine(ctx, :after),
                   on_failure: on_failure
                 )

        assert snapshot(ctx, "hold-unlocked") == before
      end
    end

    # sabotage: had migrate_tail/6 (executions.ex) refuse :needs_migration
    # with the terminal statuses -> red over both adapters: the parked hold
    # was refused as terminal. Verified red, reverted from a copy.
    test "an already-parked execution refused again stays parked as it was", ctx do
      before = waiting_hold(ctx, "hold-reparked")
      plan = plan!(ctx, :after)
      opts = [on_failure: :park, pin_sources: [QuietTimerQueue]]

      assert {:parked, {:migration_refused, _findings}} =
               migrate(ctx, "hold-reparked", plan, :after, opts)

      assert snapshot(ctx, "hold-reparked") == parked(before)

      assert {:parked, {:migration_refused, _findings}} =
               migrate(ctx, "hold-reparked", plan, :after, opts)

      assert snapshot(ctx, "hold-reparked") == parked(before)

      assert {:error, {:migration_refused, _findings}} =
               migrate(ctx, "hold-reparked", plan, :after, pin_sources: [QuietTimerQueue])

      assert snapshot(ctx, "hold-reparked") == parked(before)
    end
  end

  describe "the transformed configuration's legality" do
    # sabotage: had configuration_findings/2 (migration/transform.ex)
    # answer [] -> red over both adapters: the hold migrated with `hold`
    # and no active child. Verified red, reverted from a copy.
    test "dropped active leaf: an illegal configuration is refused, nothing written", ctx do
      before = routing_hold(ctx, "hold-dropped-leaf")
      plan = plan!(ctx, :after, rename(drop: ["routing"]))

      assert {:error, {:migration_refused, [{:illegal_configuration, ["hold"]}]}} =
               migrate(ctx, "hold-dropped-leaf", plan, :after)

      assert snapshot(ctx, "hold-dropped-leaf") == before

      assert {:parked, {:migration_refused, [{:illegal_configuration, ["hold"]}]}} =
               migrate(ctx, "hold-dropped-leaf", plan, :after, on_failure: :park)

      assert snapshot(ctx, "hold-dropped-leaf") == parked(before)
    end
  end

  describe "an invocation lands in the transformed configuration" do
    # sabotage: had outside_configuration/2 (migration/transform.ex) answer
    # [] -> red over both adapters: the hold migrated with the notice on
    # `stash`, a state it is not in. Verified red, reverted from a copy.
    test "notice moved off the configuration: refused, nothing written", ctx do
      before = waiting_hold(ctx, "hold-stashed")
      plan = plan!(ctx, :stash, invocations: [{"awaiting_pickup", 0, "stash", 0}])
      finding = {:invocation_outside_configuration, {"awaiting_pickup", 0}, {"stash", 0}}

      assert {:error, {:migration_refused, [^finding]}} =
               migrate(ctx, "hold-stashed", plan, :stash)

      assert snapshot(ctx, "hold-stashed") == before

      assert {:parked, {:migration_refused, [^finding]}} =
               migrate(ctx, "hold-stashed", plan, :stash, on_failure: :park)

      assert snapshot(ctx, "hold-stashed") == parked(before)
    end
  end
end
