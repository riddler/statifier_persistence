defmodule StatifierPersistence.ExecutionsMigrateBatchTest do
  @moduledoc """
  `StatifierPersistence.Executions.migrate_batch/3` (ADR-0017), over both
  shipped adapters.

  The fixture is a library loan. A loan waits in `awaiting_return`, whose
  entry schedules the due-date timer; a loan past its due date waits in
  `overdue`; a returned copy is checked in. Two edits of the loan's
  document are published against it:

  - the label-only edit, `@loan_checkin`: the check-in step gains a
    `damaged` outcome and nothing a waiting loan stands on changes, so a
    loan in `awaiting_return` is compatible at its position;
  - the breaking edit, `@loan_recall`: `overdue` becomes `recalled`. A
    plan that does not map it cannot take an overdue loan, and a loan in
    `awaiting_return` still moves, with its surface changed, because its
    due-date transition now targets `recalled`.

  The loan case has no durable children, so the linked cases use a hold
  whose `<invoke>` started a pickup notice as a durable child, and move
  the notice.

  Every "writes nothing" case re-reads the stored records and compares
  them whole with the ones read before the call.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, EctoHosts, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Migration.Plan

  @loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
    <state id="awaiting_return">
      <onentry>
        <send id="due" event="loan.due" delay="1209600s"/>
      </onentry>
      <transition event="copy.returned" target="checking_in"/>
      <transition event="loan.due" target="overdue"/>
    </state>
    <state id="overdue">
      <transition event="copy.returned" target="checking_in"/>
    </state>
    <state id="checking_in">
      <transition event="copy.checked" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  @loan_checkin """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
    <state id="awaiting_return">
      <onentry>
        <send id="due" event="loan.due" delay="1209600s"/>
      </onentry>
      <transition event="copy.returned" target="checking_in"/>
      <transition event="loan.due" target="overdue"/>
    </state>
    <state id="overdue">
      <transition event="copy.returned" target="checking_in"/>
    </state>
    <state id="checking_in">
      <transition event="copy.checked" target="returned"/>
      <transition event="copy.damaged" target="damaged"/>
    </state>
    <final id="returned"/>
    <final id="damaged"/>
  </scxml>
  """

  @loan_recall """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
    <state id="awaiting_return">
      <onentry>
        <send id="due" event="loan.due" delay="1209600s"/>
      </onentry>
      <transition event="copy.returned" target="checking_in"/>
      <transition event="loan.due" target="recalled"/>
    </state>
    <state id="recalled">
      <transition event="copy.returned" target="checking_in"/>
    </state>
    <state id="checking_in">
      <transition event="copy.checked" target="returned"/>
      <transition event="copy.damaged" target="damaged"/>
    </state>
    <final id="returned"/>
    <final id="damaged"/>
  </scxml>
  """

  # A loan that may be renewed while it is out: the renewal region runs
  # beside the return region. The next revision stops renewals, so the
  # renewal region is removed whole and a plan drops it.
  @renewable_loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loan">
    <parallel id="loan">
      <state id="return_region" initial="on_loan">
        <state id="on_loan">
          <transition event="copy.returned" target="checked_in"/>
        </state>
        <state id="checked_in"/>
      </state>
      <state id="renewal_region" initial="renewal_open">
        <state id="renewal_open">
          <transition event="loan.renewed" target="renewed"/>
        </state>
        <state id="renewed"/>
      </state>
    </parallel>
  </scxml>
  """

  @unrenewable_loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loan">
    <parallel id="loan">
      <state id="return_region" initial="on_loan">
        <state id="on_loan">
          <transition event="copy.returned" target="checked_in"/>
        </state>
        <state id="checked_in"/>
      </state>
    </parallel>
  </scxml>
  """

  @hold """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <state id="placed">
        <transition event="copy.available" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <invoke id="notice" type="library:pickup_notice"/>
        <transition event="done.invoke.notice" target="fulfilled"/>
      </state>
    </state>
    <final id="fulfilled"/>
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

  defmodule ReturningStrategy do
    @moduledoc false
    # A serialization strategy that, for one named execution, steps it to
    # its final state before running the section: a patron returning the
    # copy between the listing and the execution's turn. Its config is
    # `{store, machine, execution_id}`; the step takes the adapter's own
    # lock, and the section runs unlocked.
    @behaviour StatifierPersistence.Serialization

    alias StatifierPersistence.Executions

    @impl StatifierPersistence.Serialization
    def with_execution({store, machine, returned_id}, execution_id, fun) do
      if execution_id == returned_id do
        for event <- ["copy.returned", "copy.checked"] do
          {:ok, _execution, _ms} =
            Executions.step(store, execution_id, machine, Statifier.Event.external(event),
              executor: fn _effect, _context -> :ok end
            )
        end
      end

      {:ok, fun.()}
    end
  end

  defmodule RaisingStrategy do
    @moduledoc false
    # A serialization strategy that raises when an execution's turn comes:
    # a fault inside the batch, after its span opened.
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(_config, _execution_id, _fun), do: raise("the loan shelf is unreachable")
  end

  @doc false
  def forward(name, _measurements, metadata, %{pid: pid}) do
    if self() == pid, do: send(pid, {:telemetry, name, metadata})
    :ok
  end

  @doc false
  def forward_span(name, measurements, metadata, %{pid: pid}) do
    if self() == pid, do: send(pid, {:span, List.last(name), measurements, metadata})
    :ok
  end

  setup %{adapter: adapter} do
    store = store(adapter)

    machines =
      Map.new(
        [
          @loan,
          @loan_checkin,
          @loan_recall,
          @renewable_loan,
          @unrenewable_loan,
          @hold,
          @notice_before,
          @notice_after
        ],
        fn source ->
          {:ok, machine} = Statifier.compile(source)
          :ok = Storage.save_chart(store, machine, source)
          {source, machine}
        end
      )

    %{
      store: store,
      loan: machines[@loan],
      checkin: machines[@loan_checkin],
      recall: machines[@loan_recall],
      renewable: machines[@renewable_loan],
      unrenewable: machines[@unrenewable_loan],
      hold: machines[@hold],
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

  defp quiet(_effect, _context), do: :ok

  defp plan!(from, to, states \\ %{}) do
    {:ok, plan} = Plan.new(from: hash(from), to: hash(to), states: states)
    plan
  end

  # A loan created on `machine` and stepped through `events`.
  defp loan!(ctx, execution_id, events, machine \\ nil) do
    machine = machine || ctx.loan

    {:ok, _execution, _ms} =
      Executions.create(ctx.store, execution_id, machine, executor: &quiet/2)

    for event <- events do
      {:ok, _execution, _ms} =
        Executions.step(ctx.store, execution_id, machine, Event.external(event),
          executor: &quiet/2
        )
    end

    execution_id
  end

  defp park!(ctx, execution_id) do
    :ok = Storage.update_execution_status(ctx.store, execution_id, :needs_migration)
    execution_id
  end

  defp stored(ctx, execution_id) do
    {:ok, record} = Storage.fetch_execution(ctx.store, execution_id)
    record
  end

  defp batch(ctx, plan, from, to, opts \\ []) do
    Executions.migrate_batch(ctx.store, plan, [from_machine: from, to_machine: to] ++ opts)
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

  @batch_span [:statifier_persistence, :execution, :migrate_batch]

  defp attach_span do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        for(half <- [:start, :stop, :exception], do: @batch_span ++ [half]),
        &__MODULE__.forward_span/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # The hold's `<invoke>` starts the pickup notice as a durable child.
  defp notice_dispatch do
    fn "library:pickup_notice", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: @notice_before}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  # A hold whose copy is available: it waits in `awaiting_pickup`, and its
  # pickup notice waits in `notice_sent` on the notice chart, a live
  # durable child carrying a linkage.
  defp linked_notice!(ctx) do
    driver =
      Driver.new(ctx.store, ctx.hold,
        dispatch: notice_dispatch(),
        invoke_types: @invoke_types,
        chart_resolver: fn content_hash ->
          if content_hash == hash(ctx.hold), do: {:ok, ctx.hold}, else: :error
        end
      )

    {:ok, _execution, _ms} = Driver.create(driver, "hold")
    {:ok, _execution, _ms} = Driver.send_event(driver, "hold", Event.external("copy.available"))

    notice_id = Linkage.child_execution_id("hold", "notice", 0)
    assert {:ok, %Linkage{}} = Linkage.from_metadata(stored(ctx, notice_id).metadata)
    notice_id
  end

  describe "the dry run" do
    # sabotage: had preview/3 (executions.ex) answer {:would_migrate, _}
    # for a refusal -> red over both adapters: the overdue loan answered
    # :would_migrate. Verified red, reverted from a copy.
    test "answers per execution, ascending id, and writes nothing", ctx do
      loan!(ctx, "loan-2", [])
      loan!(ctx, "loan-1", ["loan.due"])
      loan!(ctx, "loan-3", [])
      park!(ctx, "loan-3")
      ids = ["loan-1", "loan-2", "loan-3"]
      before = Map.new(ids, &{&1, stored(ctx, &1)})
      attach([:statifier_persistence, :execution, :migrated])

      assert {:ok, report} =
               batch(ctx, plan!(ctx.loan, ctx.recall), ctx.loan, ctx.recall, dry_run: true)

      assert %{from: from, to: to, dry_run: true, results: results, counts: counts} = report
      assert from == hash(ctx.loan)
      assert to == hash(ctx.recall)

      assert [
               {"loan-1", {:would_refuse, {:migration_refused, findings}}},
               {"loan-2", {:would_migrate, %{dropped: [], compatible_at: false}}},
               {"loan-3", {:would_migrate, %{dropped: [], compatible_at: false}}}
             ] = results

      assert {:unmapped_state, :configuration, "overdue"} in findings
      assert counts == %{would_migrate: 2, would_refuse: 1, skipped: 0}

      for id <- ids, do: assert(stored(ctx, id) == before[id])
      refute_received {:telemetry, _name, _metadata}
    end

    # sabotage: had compatible_at?/2 (executions.ex) answer `true`
    # without asking Statifier.Position.compatible_at?/3 -> red over both
    # adapters: the loan being checked in answered compatible_at: true.
    # Verified red, reverted from a copy.
    test "asks compatible_at?/3 at each execution's own position", ctx do
      loan!(ctx, "loan-waiting", [])
      loan!(ctx, "loan-checking-in", ["copy.returned"])

      assert {:ok, %{results: results}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin, dry_run: true)

      assert results == [
               {"loan-checking-in", {:would_migrate, %{dropped: [], compatible_at: false}}},
               {"loan-waiting", {:would_migrate, %{dropped: [], compatible_at: true}}}
             ]
    end

    # sabotage: had preview_skip/1 (executions.ex) answer :ok for a
    # record carrying a linkage -> red over both adapters: the notice
    # answered {:would_migrate, _}. Verified red, reverted from a copy.
    test "skips a linked execution and names it", ctx do
      notice_id = linked_notice!(ctx)
      before = stored(ctx, notice_id)

      assert {:ok, %{results: [{^notice_id, {:skipped, :linked}}], counts: counts}} =
               batch(
                 ctx,
                 plan!(ctx.notice_from, ctx.notice_to, %{"notice_sent" => "patron_notified"}),
                 ctx.notice_from,
                 ctx.notice_to,
                 dry_run: true
               )

      assert counts == %{would_migrate: 0, would_refuse: 0, skipped: 1}
      assert stored(ctx, notice_id) == before
    end

    # sabotage: had preview_skip/1 (executions.ex) drop its terminal
    # clause -> red over both adapters: the returned loan answered
    # {:would_refuse, {:terminal_execution, _}}. Verified red, reverted
    # from a copy.
    test "skips an execution that is terminal when its turn comes", ctx do
      loan!(ctx, "loan-returned", [])

      assert {:ok, %{results: [{"loan-returned", {:skipped, :terminal}}]}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin,
                 dry_run: true,
                 serialization: {ReturningStrategy, {ctx.store, ctx.loan, "loan-returned"}}
               )
    end

    # sabotage: had apply_one/2 (executions.ex) pass `on_failure: :park`
    # whatever the batch was given -> red over both adapters: the apply
    # parked the overdue loan the dry run answered :would_refuse.
    # Verified red, reverted from a copy.
    test "and the apply agree when nothing changed between them", ctx do
      loan!(ctx, "loan-a", [])
      loan!(ctx, "loan-b", ["loan.due"])
      plan = plan!(ctx.loan, ctx.recall)

      assert {:ok, %{results: preview}} =
               batch(ctx, plan, ctx.loan, ctx.recall, dry_run: true)

      assert {:ok, %{results: applied}} = batch(ctx, plan, ctx.loan, ctx.recall)

      assert [
               {"loan-a", {:would_migrate, %{dropped: dropped}}},
               {"loan-b", {:would_refuse, reason}}
             ] = preview

      assert [
               {"loan-a", {:migrated, %{dropped: ^dropped}}},
               {"loan-b", {:refused, ^reason}}
             ] = applied
    end

    # sabotage: had preview/3 (executions.ex) answer `dropped: []` instead
    # of the transform's dropped states -> red over both adapters: the dry
    # run answered no dropped state where the apply reported the renewal
    # region's. Verified red, reverted from a copy.
    test "reports the dropped states the apply then reports", ctx do
      loan!(ctx, "loan-renewable", [], ctx.renewable)

      {:ok, plan} =
        Plan.new(
          from: hash(ctx.renewable),
          to: hash(ctx.unrenewable),
          drop: ["renewal_region", "renewal_open", "renewed"]
        )

      assert {:ok, %{results: [{"loan-renewable", {:would_migrate, preview}}]}} =
               batch(ctx, plan, ctx.renewable, ctx.unrenewable, dry_run: true)

      assert preview.dropped == ["renewal_open", "renewal_region"]

      assert {:ok, %{results: [{"loan-renewable", {:migrated, facts}}]}} =
               batch(ctx, plan, ctx.renewable, ctx.unrenewable)

      assert facts.dropped == preview.dropped
    end
  end

  describe "the apply" do
    # sabotage: had migrate_batch/3 (executions.ex) default `on_failure:`
    # to :park -> red over both adapters: the overdue loan was parked
    # under the default. Verified red, reverted from a copy.
    test "refuses by default: a refused loan stays :active on from", ctx do
      loan!(ctx, "loan-a", [])
      loan!(ctx, "loan-b", ["loan.due"])
      refused_before = stored(ctx, "loan-b")
      attach([:statifier_persistence, :execution, :migrated])

      assert {:ok, %{dry_run: false, results: results, counts: counts}} =
               batch(ctx, plan!(ctx.loan, ctx.recall), ctx.loan, ctx.recall)

      assert [
               {"loan-a", {:migrated, facts}},
               {"loan-b", {:refused, {:migration_refused, _findings}}}
             ] = results

      assert facts == %{
               from_content_hash: hash(ctx.loan),
               to_content_hash: hash(ctx.recall),
               dropped: []
             }

      assert counts == %{migrated: 1, refused: 1, parked: 0, skipped: 0}

      assert stored(ctx, "loan-b") == refused_before
      assert %{status: :active, content_hash: from} = refused_before
      assert from == hash(ctx.loan)

      assert %{status: :active, content_hash: to} = stored(ctx, "loan-a")
      assert to == hash(ctx.recall)
      {:ok, moved} = Storage.load_execution_position(ctx.store, "loan-a", ctx.recall)
      assert leaves(moved) == ["awaiting_return"]

      assert_received {:telemetry, [:statifier_persistence, :execution, :migrated],
                       %{execution_id: "loan-a"}}

      refute_received {:telemetry, _name, _metadata}
    end

    # sabotage: had apply_one/2 (executions.ex) map {:parked, reason} to
    # {:refused, reason} -> red over both adapters: the report named no
    # parked id although the store had parked the overdue loans. Verified
    # red, reverted from a copy.
    test "with on_failure: :park parks what it cannot take and lists every parked id", ctx do
      loan!(ctx, "loan-a", [])
      loan!(ctx, "loan-b", ["loan.due"])
      loan!(ctx, "loan-c", ["loan.due"])

      assert {:ok, %{results: results, counts: counts}} =
               batch(ctx, plan!(ctx.loan, ctx.recall), ctx.loan, ctx.recall, on_failure: :park)

      parked = for {id, {:parked, {:migration_refused, _}}} <- results, do: id
      assert parked == ["loan-b", "loan-c"]
      assert counts == %{migrated: 1, refused: 0, parked: 2, skipped: 0}

      for id <- parked do
        assert %{status: :needs_migration, content_hash: from} = stored(ctx, id)
        assert from == hash(ctx.loan)
      end
    end

    # sabotage: had migrate_listed/1 (executions.ex) list [:active] alone ->
    # red over both adapters: the parked loan was not in the batch and
    # stayed :needs_migration on from. Verified red, reverted from a copy.
    test "takes the parked executions on from too, and a corrected plan un-parks them", ctx do
      loan!(ctx, "loan-parked", [])
      park!(ctx, "loan-parked")

      assert {:ok, %{results: [{"loan-parked", {:migrated, _facts}}]}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin)

      assert %{status: :active, content_hash: to} = stored(ctx, "loan-parked")
      assert to == hash(ctx.checkin)
    end

    # sabotage: had apply_one/2 (executions.ex) map every {:error, _} to
    # {:refused, _} -> red over both adapters: the loan returned before
    # its turn answered {:refused, {:terminal_execution, _}}. Verified
    # red, reverted from a copy.
    test "skips an execution that is terminal when its turn comes", ctx do
      loan!(ctx, "loan-returned", [])
      loan!(ctx, "loan-waiting", [])

      assert {:ok, %{results: results, counts: counts}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin,
                 serialization: {ReturningStrategy, {ctx.store, ctx.loan, "loan-returned"}}
               )

      assert [
               {"loan-returned", {:skipped, :terminal}},
               {"loan-waiting", {:migrated, _facts}}
             ] = results

      assert counts == %{migrated: 1, refused: 0, parked: 0, skipped: 1}
      assert %{status: :completed, content_hash: from} = stored(ctx, "loan-returned")
      assert from == hash(ctx.loan)
    end

    # sabotage: had batch_one/3's apply clause (executions.ex) call
    # apply_one/2 for a linked execution -> red over both adapters: the
    # notice answered {:refused, {:linked, _}} and stayed on the old
    # notice chart. Verified red, reverted from a copy.
    test "moves a linked execution through the tree migration, its linkage pin with it", ctx do
      notice_id = linked_notice!(ctx)
      {:ok, linkage_before} = Linkage.from_metadata(stored(ctx, notice_id).metadata)
      hold_before = stored(ctx, "hold")

      assert {:ok, %{results: [{^notice_id, {:migrated, facts}}], counts: counts}} =
               batch(
                 ctx,
                 plan!(ctx.notice_from, ctx.notice_to, %{"notice_sent" => "patron_notified"}),
                 ctx.notice_from,
                 ctx.notice_to
               )

      assert facts.from_content_hash == hash(ctx.notice_from)
      assert facts.to_content_hash == hash(ctx.notice_to)
      assert counts == %{migrated: 1, refused: 0, parked: 0, skipped: 0}

      notice = stored(ctx, notice_id)
      assert notice.content_hash == hash(ctx.notice_to)
      assert {:ok, linkage} = Linkage.from_metadata(notice.metadata)
      assert linkage == %{linkage_before | content_hash: hash(ctx.notice_to)}

      {:ok, notice_state} = Storage.load_execution_position(ctx.store, notice_id, ctx.notice_to)
      assert leaves(notice_state) == ["patron_notified"]

      # The parent is on another chart and is not this batch's.
      assert stored(ctx, "hold") == hold_before
    end

    # sabotage: had apply_tree/2 (executions.ex) build `plans` keyed by
    # the plan's from hash instead of the execution id -> red over both
    # adapters: the reverse batch answered {:refused, {:not_in_tree, _}}.
    # Verified red, reverted from a copy.
    test "a reverse plan returns a migrated loan and a migrated child to from", ctx do
      loan!(ctx, "loan-a", [])
      notice_id = linked_notice!(ctx)

      assert {:ok, %{counts: %{migrated: 1}}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin)

      assert {:ok, %{counts: %{migrated: 1}}} =
               batch(
                 ctx,
                 plan!(ctx.notice_from, ctx.notice_to, %{"notice_sent" => "patron_notified"}),
                 ctx.notice_from,
                 ctx.notice_to
               )

      assert {:ok, %{results: [{"loan-a", {:migrated, back}}]}} =
               batch(ctx, plan!(ctx.checkin, ctx.loan), ctx.checkin, ctx.loan)

      assert back.to_content_hash == hash(ctx.loan)
      assert stored(ctx, "loan-a").content_hash == hash(ctx.loan)
      {:ok, loan_state} = Storage.load_execution_position(ctx.store, "loan-a", ctx.loan)
      assert leaves(loan_state) == ["awaiting_return"]

      reverse = plan!(ctx.notice_to, ctx.notice_from, %{"patron_notified" => "notice_sent"})

      assert {:ok, %{results: [{^notice_id, {:migrated, _facts}}]}} =
               batch(ctx, reverse, ctx.notice_to, ctx.notice_from)

      notice = stored(ctx, notice_id)
      assert notice.content_hash == hash(ctx.notice_from)
      assert {:ok, %Linkage{content_hash: pin}} = Linkage.from_metadata(notice.metadata)
      assert pin == hash(ctx.notice_from)
    end

    # ADR-0017 decision 7: once from is retired, the reverse plan's `to`,
    # the whole batch is refused with the retired arm before anything is
    # read.
    #
    # sabotage: had migrate_listed/1 (executions.ex) drop plan_check/5 ->
    # red over both adapters: the reverse batch answered {:ok, _} and
    # tried the loan. Verified red, reverted from a copy.
    test "a reverse plan onto a retired chart is refused whole", ctx do
      loan!(ctx, "loan-a", [])

      assert {:ok, %{counts: %{migrated: 1}}} =
               batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin)

      assert {:ok, _retired} =
               Executions.retire_chart(ctx.store, hash(ctx.loan), [], retired_by: "librarian")

      before = stored(ctx, "loan-a")

      assert {:error, {:chart_retired, _info}} =
               batch(ctx, plan!(ctx.checkin, ctx.loan), ctx.checkin, ctx.loan)

      assert stored(ctx, "loan-a") == before
    end
  end

  describe "the whole-batch refusals" do
    # sabotage: had migrate_listed/1 (executions.ex) drop plan_check/5 -> red
    # over both adapters: an invalid plan answered {:ok, _} with every
    # loan refused one by one. Verified red, reverted from a copy.
    test "a static fault refuses before any execution is read", ctx do
      loan!(ctx, "loan-a", [])
      before = stored(ctx, "loan-a")
      plan = plan!(ctx.loan, ctx.checkin, %{"no_such_state" => "awaiting_return"})

      for dry_run <- [true, false] do
        assert {:error, {:invalid_plan, _findings}} =
                 batch(ctx, plan, ctx.loan, ctx.checkin, dry_run: dry_run, on_failure: :park)
      end

      assert stored(ctx, "loan-a") == before
    end

    # sabotage: had check_batch_opts!/3 (executions.ex) accept any
    # :dry_run value -> red over both adapters: a string dry run got past
    # the option check and raised no ArgumentError. Verified red,
    # reverted from a copy.
    test "a malformed option raises before anything is read", ctx do
      loan!(ctx, "loan-a", [])
      before = stored(ctx, "loan-a")
      plan = plan!(ctx.loan, ctx.checkin)

      assert_raise ArgumentError, ~r/:dry_run/, fn ->
        batch(ctx, plan, ctx.loan, ctx.checkin, dry_run: "yes")
      end

      assert_raise ArgumentError, ~r/:on_failure/, fn ->
        batch(ctx, plan, ctx.loan, ctx.checkin, on_failure: :skip)
      end

      assert stored(ctx, "loan-a") == before
    end
  end

  describe "the batch span (ADR-0017 decision 6)" do
    # sabotage: had batch_span/3 (executions.ex) emit the stop with an
    # empty counts map -> red over both adapters: the stop carried no
    # :migrated or :refused measurement. Verified red, reverted from a copy.
    test "an apply opens it, and its stop carries the report's counts", ctx do
      loan!(ctx, "loan-a", [])
      loan!(ctx, "loan-b", ["loan.due"])
      attach_span()
      attach([:statifier_persistence, :execution, :migrated])

      assert {:ok, %{counts: counts}} =
               batch(ctx, plan!(ctx.loan, ctx.recall), ctx.loan, ctx.recall)

      assert_received {:span, :start, start_m, start_meta}
      assert %{system_time: _, monotonic_time: started_at} = start_m
      from = hash(ctx.loan)
      to = hash(ctx.recall)

      assert %{from: ^from, to: ^to, dry_run: false, span_ref: span_ref} = start_meta
      assert is_reference(span_ref)

      assert_received {:telemetry, [:statifier_persistence, :execution, :migrated],
                       %{execution_id: "loan-a"}}

      assert_received {:span, :stop, stop_m, stop_meta}

      assert %{
               from: ^from,
               to: ^to,
               dry_run: false,
               span_ref: ^span_ref,
               outcome: :ok,
               reason: nil
             } = stop_meta

      assert %{duration: duration, monotonic_time: stopped_at} = stop_m
      assert duration == stopped_at - started_at
      assert Map.drop(stop_m, [:duration, :monotonic_time]) == counts
      assert counts == %{migrated: 1, refused: 1, parked: 0, skipped: 0}
      refute_received {:span, _half, _measurements, _metadata}
    end

    # sabotage: had migrate_batch/3 (executions.ex) call migrate_listed/1
    # outside batch_span/3 when dry_run is true -> red over both adapters:
    # the dry run emitted no start. Verified red, reverted from a copy.
    test "a dry run opens it, with the dry run's counts and no :migrated", ctx do
      loan!(ctx, "loan-a", [])
      loan!(ctx, "loan-b", ["loan.due"])
      attach_span()
      attach([:statifier_persistence, :execution, :migrated])

      assert {:ok, %{counts: counts}} =
               batch(ctx, plan!(ctx.loan, ctx.recall), ctx.loan, ctx.recall, dry_run: true)

      assert_received {:span, :start, _start_m, %{dry_run: true, span_ref: span_ref}}
      assert_received {:span, :stop, stop_m, stop_meta}
      assert %{dry_run: true, span_ref: ^span_ref, outcome: :ok, reason: nil} = stop_meta
      assert Map.drop(stop_m, [:duration, :monotonic_time]) == counts
      assert counts == %{would_migrate: 1, would_refuse: 1, skipped: 0}
      refute_received {:telemetry, _name, _metadata}
      refute_received {:span, _half, _measurements, _metadata}
    end

    # sabotage: had batch_span/3 (executions.ex) match no {:error, _}
    # result -> red over both adapters: a refused batch raised instead of
    # closing its span with :error. Verified red, reverted from a copy.
    test "a whole-batch refusal closes it with :error, the refusal and zero counts", ctx do
      loan!(ctx, "loan-a", [])
      attach_span()
      plan = plan!(ctx.loan, ctx.checkin, %{"no_such_state" => "awaiting_return"})

      for {dry_run, zeros} <- [
            {true, %{would_migrate: 0, would_refuse: 0, skipped: 0}},
            {false, %{migrated: 0, refused: 0, parked: 0, skipped: 0}}
          ] do
        assert {:error, {:invalid_plan, _findings} = reason} =
                 batch(ctx, plan, ctx.loan, ctx.checkin, dry_run: dry_run)

        assert_received {:span, :start, _start_m, %{dry_run: ^dry_run, span_ref: span_ref}}
        assert_received {:span, :stop, stop_m, stop_meta}

        assert %{dry_run: ^dry_run, span_ref: ^span_ref, outcome: :error, reason: ^reason} =
                 stop_meta

        assert Map.drop(stop_m, [:duration, :monotonic_time]) == zeros
      end

      refute_received {:span, _half, _measurements, _metadata}
    end

    # sabotage: had batch_span/3 (executions.ex)'s catch clause match no
    # kind -> red over both adapters: the raise reached the caller with
    # the span left open and no :exception. Verified red, reverted from a
    # copy.
    test "a raise inside the batch closes it with :exception and reaches the caller", ctx do
      loan!(ctx, "loan-a", [])
      attach_span()

      for dry_run <- [true, false] do
        assert_raise RuntimeError, "the loan shelf is unreachable", fn ->
          batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin,
            dry_run: dry_run,
            serialization: {RaisingStrategy, nil}
          )
        end

        assert_received {:span, :start, %{monotonic_time: started_at}, start_meta}
        assert %{dry_run: ^dry_run, span_ref: span_ref} = start_meta
        assert_received {:span, :exception, exc_m, exc_meta}
        assert %{duration: duration, monotonic_time: raised_at} = exc_m
        assert duration == raised_at - started_at
        assert map_size(exc_m) == 2

        assert %{
                 from: from,
                 to: to,
                 dry_run: ^dry_run,
                 span_ref: ^span_ref,
                 kind: :error,
                 reason: RuntimeError,
                 stacktrace: [_ | _]
               } = exc_meta

        assert from == hash(ctx.loan)
        assert to == hash(ctx.checkin)
        refute_received {:span, :stop, _measurements, _metadata}
      end
    end

    # sabotage: had migrate_batch/3 (executions.ex) emit a start before
    # check_batch_opts!/3 -> red over both adapters: a malformed option
    # emitted a start. Verified red, reverted from a copy.
    test "a malformed option raises before it opens", ctx do
      attach_span()

      assert_raise ArgumentError, fn ->
        batch(ctx, plan!(ctx.loan, ctx.checkin), ctx.loan, ctx.checkin, dry_run: "yes")
      end

      refute_received {:span, _half, _measurements, _metadata}
    end
  end

  describe "the listing by status set" do
    # sabotage: had Storage.list_execution_ids_by_content_hash/3 hand the
    # adapter [:active] whatever it was asked -> red over both adapters:
    # the parked loan was not listed. Verified red, reverted from a copy.
    test "names the executions on the hash in the asked statuses, ascending", ctx do
      loan!(ctx, "loan-c", [])
      loan!(ctx, "loan-a", [])
      park!(ctx, loan!(ctx, "loan-b", []))
      loan!(ctx, "loan-d", ["copy.returned", "copy.checked"])
      loan!(ctx, "loan-e", [], ctx.checkin)

      assert {:ok, ["loan-a", "loan-b", "loan-c"]} =
               Storage.list_execution_ids_by_content_hash(ctx.store, hash(ctx.loan), [
                 :active,
                 :needs_migration
               ])

      assert {:ok, ["loan-b"]} =
               Storage.list_execution_ids_by_content_hash(ctx.store, hash(ctx.loan), [
                 :needs_migration
               ])

      assert {:ok, ["loan-d"]} =
               Storage.list_execution_ids_by_content_hash(ctx.store, hash(ctx.loan), [:completed])

      assert {:ok, []} =
               Storage.list_execution_ids_by_content_hash(ctx.store, "sha256:never-stored", [
                 :active,
                 :needs_migration
               ])

      # The :active-only listing a pin source is handed is unchanged.
      assert {:ok, active} =
               Storage.list_active_execution_ids_by_content_hash(ctx.store, hash(ctx.loan))

      assert Enum.sort(active) == ["loan-a", "loan-c"]
    end

    # sabotage: had Storage.list_execution_ids_by_content_hash/3 drop its
    # status-set guard -> red over both adapters: an empty set answered
    # {:ok, []} instead of raising. Verified red, reverted from a copy.
    test "refuses a status set that is empty or names no stored status", ctx do
      for statuses <- [[], [:running], :active] do
        assert_raise ArgumentError, ~r/statuses/, fn ->
          Storage.list_execution_ids_by_content_hash(ctx.store, hash(ctx.loan), statuses)
        end
      end
    end
  end
end

defmodule StatifierPersistence.ExecutionsMigrateBatchListingTest do
  @moduledoc """
  `StatifierPersistence.Executions.migrate_batch/3` against an adapter
  that cannot list the executions on a hash (ADR-0017 decision 9): the
  whole batch is refused before any execution is read, and nothing is
  written.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.Migration.Plan
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.{NoChildListingAdapter, NoTombstoneReadAdapter}

  defmodule RefusingListingAdapter do
    @moduledoc false
    # The in-memory adapter, with the listing by status set answering an
    # error of its own, as a host adapter that cannot serve it may.
    @behaviour StatifierPersistence.Storage.Adapter

    @impl true
    defdelegate init(opts), to: InMemory
    @impl true
    defdelegate save_chart(opts, chart_record), to: InMemory
    @impl true
    defdelegate fetch_chart(opts, content_hash), to: InMemory
    @impl true
    defdelegate save_position(opts, position_record), to: InMemory
    @impl true
    defdelegate fetch_position(opts, session_id), to: InMemory
    @impl true
    defdelegate insert_execution(opts, execution_record), to: InMemory
    @impl true
    defdelegate fetch_execution(opts, execution_id), to: InMemory
    @impl true
    defdelegate update_execution(opts, execution_record), to: InMemory
    @impl true
    defdelegate lock_execution(opts, execution_id, fun), to: InMemory
    @impl true
    defdelegate supports_content_hash_query?(opts), to: InMemory
    @impl true
    defdelegate count_executions_by_content_hash(opts, content_hash), to: InMemory

    @impl true
    defdelegate list_active_execution_ids_by_content_hash(opts, content_hash), to: InMemory

    @impl true
    def list_execution_ids_by_content_hash(_opts, _content_hash, _statuses),
      do: {:error, {:adapter, :listing_unavailable}}
  end

  @loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
    <state id="awaiting_return">
      <transition event="copy.returned" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  @loan_checkin """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
    <state id="awaiting_return">
      <transition event="copy.returned" target="returned"/>
      <transition event="copy.damaged" target="damaged"/>
    </state>
    <final id="returned"/>
    <final id="damaged"/>
  </scxml>
  """

  @doc false
  def forward(_name, _measurements, metadata, %{pid: pid}) do
    if self() == pid, do: send(pid, {:adapter_call, metadata.callback})
    :ok
  end

  setup do
    {:ok, from} = Statifier.compile(@loan)
    {:ok, to} = Statifier.compile(@loan_checkin)

    {:ok, plan} =
      Plan.new(from: from.identity.content_hash, to: to.identity.content_hash, states: %{})

    %{from: from, to: to, plan: plan}
  end

  defp loaned_store(adapter, ctx) do
    {:ok, store} = Storage.new(adapter, [])

    for {machine, source} <- [{ctx.from, @loan}, {ctx.to, @loan_checkin}] do
      :ok = Storage.save_chart(store, machine, source)
    end

    {:ok, _execution, _ms} =
      Executions.create(store, "loan-a", ctx.from, executor: fn _effect, _context -> :ok end)

    {:ok, before} = Storage.fetch_execution(store, "loan-a")
    {store, before}
  end

  defp attach_calls do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:statifier_persistence, :adapter, :call],
        &__MODULE__.forward/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp calls(acc \\ []) do
    receive do
      {:adapter_call, callback} -> calls([callback | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # sabotage: had migrate_listed/1 (executions.ex) fall back to
  # list_active_execution_ids_by_content_hash/2 when the listing refused
  # -> red: against the adapter that declares the capability without the
  # export, the batch answered {:ok, _} and read the loan. Verified red,
  # reverted from a copy.
  test "an adapter without the capability, or without the export, refuses the whole batch",
       ctx do
    for {adapter, reason} <- [
          {NoChildListingAdapter, :content_hash_query_unsupported},
          {NoTombstoneReadAdapter, :content_hash_query_unsupported},
          {RefusingListingAdapter, {:adapter, :listing_unavailable}}
        ],
        dry_run <- [true, false] do
      {store, before} = loaned_store(adapter, ctx)
      attach_calls()
      calls()

      assert {:error, ^reason} =
               Executions.migrate_batch(store, ctx.plan,
                 from_machine: ctx.from,
                 to_machine: ctx.to,
                 dry_run: dry_run
               )

      read = calls()
      refute :fetch_execution in read, "#{inspect(adapter)} read an execution: #{inspect(read)}"
      refute :fetch_position in read
      refute :list_active_execution_ids_by_content_hash in read

      assert {:ok, ^before} = Storage.fetch_execution(store, "loan-a")
    end
  end

  # sabotage: had Storage.list_execution_ids_by_content_hash/3 drop its
  # function_exported?/3 check -> red: the adapter written before the
  # callback raised UndefinedFunctionError instead of answering the
  # refusal. Verified red, reverted from a copy.
  test "the facade answers the refusal for an adapter declaring the capability without the export",
       ctx do
    {store, _before} = loaned_store(NoTombstoneReadAdapter, ctx)
    assert Storage.content_hash_query_supported?(store)

    assert {:error, :content_hash_query_unsupported} =
             Storage.list_execution_ids_by_content_hash(
               store,
               ctx.from.identity.content_hash,
               [:active]
             )
  end
end
