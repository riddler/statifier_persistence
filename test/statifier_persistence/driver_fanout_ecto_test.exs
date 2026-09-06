defmodule StatifierPersistence.DriverFanoutEctoTest do
  @moduledoc """
  The `first_error` settlement (sp-t57) against
  `StatifierPersistence.Storage.Ecto` over real Postgres (ADR-0005) - the
  Postgres half of sp-oq4's lock-order audit, which
  `driver_fanout_test.exs` cannot cover.

  `DriverSubchartEctoTest` already proves that a cascade's nested
  `lock_run/3` calls commit rather than deadlocking when the cascade fires
  from inside the run's OWN exclusion. The settlement path is the other
  shape and the one the audit is about: `Driver.decide/4` opens the
  exclusion on the PARENT while the caller is a child's driver, and
  `Driver.maybe_cancel/4` then runs the whole cascade over the siblings
  inside it - so one Postgres transaction takes
  `pg_advisory_xact_lock(parent)`, then `SELECT ... FOR UPDATE` on the
  parent row, then the same pair on each sibling in turn, and holds every
  one of them until it commits.

  What makes that safe is the direction, which `driver_fanout_test.exs`
  pins and this case runs for real: every lock taken while another is held
  is on a strict descendant of it (`Run.Linkage.child_run_id/3` makes a
  child's id strictly extend its parent's), so the wait-for relation
  between connections embeds in the run tree, and the run tree is acyclic
  by construction (ADR-0008 decision 6). A plain pass is the
  confirmation - a `deadlock detected` or a lock timeout is what a cycle
  would look like here.

  `async: false`, the same reason `DriverSubchartEctoTest` gives: one
  sandbox-checked-out connection drives every `Storage.new/2` handle in a
  test.
  """

  use ExUnit.Case, async: false

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Run.Linkage

  @adapter Storage.Ecto
  @adapter_opts [persistence: EctoHosts.Default, sandbox: true]

  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
          <transition event="done.invoke.call" target="approved"/>
      </state>
      <state id="approved"/>
  </scxml>
  """

  # The same child as the in-memory fan-out's: "go" completes with the
  # seeded item, "refuse" reaches a failure-classed final (ADR-0008's
  # 2026-09-06 amendment) and takes its own run to :failed with no host
  # translation, which is what fires `first_error`.
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <datamodel><data id="item"/></datamodel>
      <state id="idle">
          <transition event="go" target="done"/>
          <transition event="refuse" target="refused"/>
      </state>
      <final id="done">
          <donedata><content expr="item"/></donedata>
      </final>
      <final id="refused">
          <donedata>
              <param name="statifier_persistence:run_status" expr="'failed'"/>
          </donedata>
      </final>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(@adapter, @adapter_opts)
    :ok = @adapter.isolate(store.opts)
    %{store: store}
  end

  # The acquisition order this run takes, read off the query log
  # (`pg_advisory_xact_lock` per transaction, `begin`-to-`commit`):
  #
  #   each child's own drive       begin [C_i] commit
  #   index 0's settlement         begin [P] commit
  #   index 1's first_error        begin [P, C_2, C_0, C_1] commit
  #   the parent's own step        begin [P, C_0, C_1, C_2] commit
  #
  # Parent first, descendants after, in every transaction that holds more
  # than one - and a child's own exclusion is committed and released
  # before the settlement that follows it asks for the parent's. No
  # connection ever holds a descendant and waits for an ancestor, which is
  # the edge a cycle would need.
  #
  # sabotage: in Driver.decide/4, take the exclusion on `child_run_id`
  # instead of `linkage.parent_run_id` -> this case still PASSED, and that
  # is itself the finding: `pg_advisory_xact_lock` is session-reentrant
  # and Ecto nests `lock_run/3` on the one checked-out connection, so a
  # mis-ordered acquisition inside a single connection is invisible to
  # Postgres. The in-memory pin in `driver_fanout_test.exs` went red on
  # the same edit. That is the pair's division of labour and why both
  # exist: the order is pinned there, and run for real here.
  # sabotage: in Driver.maybe_cancel/4, answer {:ok, states, false} from
  # the :first_error clause without running the cascade -> red here, the
  # live index 2 stayed :active over Postgres and the parent never left
  # "calling". Verified red, reverted.
  test "a first_error settlement's cascade commits under nested Ecto lock_run/3 transactions", %{
    store: store
  } do
    parent = start_parent(store)

    for index <- 0..2 do
      assert :ok =
               Driver.start_child_at(parent, "run_ecto_fanout", effect("item-#{index}"), index, 3,
                 policy: :first_error
               )
    end

    assert :ok = finish_child(store, 0, "go")
    assert leaves(reload_parent(store)) == ["calling"]

    # Index 1's own drive takes it to :failed and answers the parent. That
    # settlement holds the parent's exclusion and cascades over all three
    # siblings from inside it - the acquisition order under audit.
    assert :ok = finish_child(store, 1, "refuse")

    assert leaves(reload_parent(store)) == ["approved"]

    for {index, status} <- [{0, :completed}, {1, :failed}, {2, :cancelled}] do
      run_id = Linkage.child_run_id("run_ecto_fanout", "call", index)
      assert {:ok, record} = Storage.fetch_run(store, run_id)
      assert record.status == status, "index #{index} was #{record.status}, not #{status}"
    end
  end

  defp start_parent(store) do
    driver = driver(store, @parent_source, fn "myapp:map", _params, _context -> :pending end)
    {:ok, _run, _machine_state} = Driver.create(driver, "run_ecto_fanout")
    driver
  end

  defp finish_child(store, index, event) do
    child_run_id = Linkage.child_run_id("run_ecto_fanout", "call", index)

    assert {:ok, _run, _machine_state} =
             Driver.send_event(child_driver(store), child_run_id, Event.external(event))

    :ok
  end

  # A driver over the child's chart that can reach the parent's: the shape
  # every node answering a durable child automatically has.
  defp child_driver(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    parent_hash = Machine.identity(parent_machine).content_hash

    resolver = fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end

    driver(store, @child_source, fn _type, _params, _context -> :pending end,
      chart_resolver: resolver
    )
  end

  defp effect(item) do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: %{"item" => item},
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end

  defp driver(store, source, dispatch, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [dispatch: dispatch, invoke_types: InvokeTypes.new(types: ["myapp:map"])],
        opts
      )
    )
  end

  defp reload_parent(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    {:ok, machine_state} = Storage.load_run_position(store, "run_ecto_fanout", parent_machine)
    machine_state
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
