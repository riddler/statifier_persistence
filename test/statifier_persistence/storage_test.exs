defmodule StatifierPersistence.StorageTest do
  use ExUnit.Case, async: true

  alias Statifier.Machine
  alias Statifier.Machine.Identity
  alias Statifier.MachineState
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.NoLockAdapter
  alias StatifierPersistence.Testing.Charts

  defmodule FailingAdapter do
    @moduledoc false
    @behaviour StatifierPersistence.Storage.Adapter

    @impl StatifierPersistence.Storage.Adapter
    def init(_opts), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def save_chart(_opts, _chart_record), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def fetch_chart(_opts, _content_hash), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def save_position(_opts, _position_record), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def fetch_position(_opts, _session_id), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def insert_execution(_opts, _execution_record), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def fetch_execution(_opts, _execution_id), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def update_execution(_opts, _execution_record), do: {:error, {:adapter, :boom}}
  end

  # The conformance suite (test/statifier_persistence/storage/in_memory_conformance_test.exs,
  # via StatifierPersistence.Testing.StorageConformance) covers every guard
  # and round-trip assertion this module used to make - the guarded round
  # trip, the cross-revision mismatch, corrupt bytes, and every
  # unidentified-machine refusal - across every adapter. What is left here
  # is genuinely specific to this module's own construction: `new/2`.

  # sabotage: in Storage.new/2, ignore adapter.init/1's result entirely and
  # always return {:ok, %__MODULE__{adapter: adapter, opts: opts}} with the
  # caller-supplied opts unchanged -> red, this test's assertion that the
  # built store threads InMemory's own :pid through would fail, and the
  # next test's assertion on the {:error, _} arm would fail too, because
  # there would be no way for init/1's own failure to reach the caller.
  # Verified red (both tests below), reverted.
  test "new/2 initializes the adapter and returns a store carrying its opts" do
    assert {:ok, store} = Storage.new(InMemory, [])

    assert %Storage{adapter: InMemory, opts: opts} = store
    assert is_pid(Keyword.fetch!(opts, :pid))
  end

  # sabotage: same mutation as the test above.
  test "new/2 returns the adapter's own init/1 failure unchanged" do
    assert {:error, {:adapter, :boom}} = Storage.new(FailingAdapter, [])
  end

  # -- Execution records: the facade arms Phase 2 adds ----------------------

  describe "execution records" do
    setup do
      {:ok, store} = Storage.new(InMemory, [])
      %{store: store}
    end

    # sabotage: in Storage.insert_execution/5, replace the
    # store.adapter.insert_execution(store.opts, execution_record) call with a bare :ok
    # that never writes -> red, fetch_execution/2 below returned
    # {:error, :execution_not_found} instead of the record. Verified red,
    # reverted.
    test "insert_execution/5 and load_execution_position/3: the guarded round trip", %{
      store: store
    } do
      {_source, machine} = Charts.chart_a()

      machine_state =
        MachineState.new(machine,
          session_id: "sess_execution_round_trip",
          datamodel: %{"count" => 1}
        )

      assert :ok = Storage.insert_execution(store, "execution-round-trip", machine_state, :active)

      assert {:ok, record} = Storage.fetch_execution(store, "execution-round-trip")
      assert %{status: :active, failure: nil} = record
      assert record.content_hash == Machine.identity(machine).content_hash

      assert {:ok, loaded} =
               Storage.load_execution_position(store, "execution-round-trip", machine)

      assert loaded.configuration == machine_state.configuration
      assert loaded.datamodel == machine_state.datamodel
      assert loaded.status == machine_state.status
    end

    # sabotage: in Storage.insert_execution/5, replace the nil-identity refusal
    # arm with a write of a dummy-identity record (content_hash "dummy",
    # empty identity_blob) -> red, this test's assertion that the insert is
    # refused failed (it returned :ok). Verified red, reverted.
    test "insert_execution/5 refuses an unidentified machine, and nothing is written", %{
      store: store
    } do
      machine_state =
        MachineState.new(Charts.unidentified_machine(), session_id: "sess_execution_unidentified")

      assert {:error, :unidentified_chart} =
               Storage.insert_execution(store, "execution-unidentified", machine_state, :active,
                 position: :skip
               )

      assert {:error, :execution_not_found} =
               Storage.fetch_execution(store, "execution-unidentified")
    end

    # sabotage: in Storage.update_execution/5, replace the nil-identity refusal
    # arm with a fetch-and-overwrite of the stored record's status and
    # failure -> red, this test's assertion that the update is refused
    # failed (it returned :ok). Verified red, reverted.
    test "update_execution/5 refuses an unidentified machine", %{store: store} do
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_execution_update_unidentified")

      assert :ok =
               Storage.insert_execution(
                 store,
                 "execution-update-unidentified",
                 machine_state,
                 :active
               )

      unidentified_state =
        MachineState.new(Charts.unidentified_machine(),
          session_id: "sess_execution_update_unidentified"
        )

      assert {:error, :unidentified_chart} =
               Storage.update_execution(
                 store,
                 "execution-update-unidentified",
                 unidentified_state,
                 :failed,
                 position: :skip
               )
    end

    # sabotage: in Storage.load_execution_position/3, replace the whole with-chain
    # (fetch_execution -> precheck_identity/2 -> nil arm -> Position.from_binary/2)
    # with a body that fetches the execution record and unconditionally returns
    # {:ok, MachineState.new(machine)} -> red, this test saw a plain
    # {:ok, _} instead of {:identity_mismatch, _, _} (the round-trip,
    # unidentified, and missing-position tests in this describe went red
    # under the same mutation). Verified red, reverted.
    test "load_execution_position/3 refuses a different chart revision, not raised", %{
      store: store
    } do
      {_source_a, machine_a} = Charts.chart_a()
      {_source_b, machine_b} = Charts.chart_b()

      refute Identity.matches?(Machine.identity(machine_a), Machine.identity(machine_b))

      machine_state = MachineState.new(machine_a, session_id: "sess_execution_mismatch")

      assert :ok = Storage.insert_execution(store, "execution-mismatch", machine_state, :active)

      assert {:error, {:identity_mismatch, expected, actual}} =
               Storage.load_execution_position(store, "execution-mismatch", machine_b)

      assert expected.content_hash == Machine.identity(machine_a).content_hash
      assert actual.content_hash == Machine.identity(machine_b).content_hash
    end

    # sabotage: in Storage's private precheck_identity/2, delete the
    # %Machine{identity: nil} -> {:error, :unidentified_chart} clause ->
    # red, Identity.matches?/2 is total and this test saw an
    # {:identity_mismatch, _, nil} tuple instead of :unidentified_chart.
    # Verified red, reverted.
    test "load_execution_position/3 refuses an unidentified machine as :unidentified_chart", %{
      store: store
    } do
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_execution_load_unidentified")

      assert :ok =
               Storage.insert_execution(
                 store,
                 "execution-load-unidentified",
                 machine_state,
                 :active
               )

      assert {:error, :unidentified_chart} =
               Storage.load_execution_position(
                 store,
                 "execution-load-unidentified",
                 Charts.unidentified_machine()
               )
    end

    # sabotage: in Storage.load_execution_position/3, change the nil
    # position_blob arm to return {:error, :execution_not_found} instead of
    # :execution_position_missing -> red, this test's pattern match on the
    # dedicated arm saw the wrong error. Verified red, reverted.
    test "load_execution_position/3 reports :execution_position_missing for a nil position_blob",
         %{
           store: store
         } do
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_execution_no_position")

      assert :ok =
               Storage.insert_execution(store, "execution-no-position", machine_state, :failed,
                 position: :skip,
                 failure: "budget_exhausted: 100 rounds"
               )

      assert {:ok, %{position_blob: nil, failure: "budget_exhausted: 100 rounds"}} =
               Storage.fetch_execution(store, "execution-no-position")

      assert {:error, :execution_position_missing} =
               Storage.load_execution_position(store, "execution-no-position", machine)
    end

    # sabotage: in Storage's private update_position_blob/4, change the
    # :skip clause to return {:ok, nil} instead of fetching the current
    # record and carrying its position_blob forward -> red, the equality
    # assertion on stored_blob below saw nil. Verified red, reverted.
    test "update_execution/5 under position: :skip carries the stored blob forward verbatim", %{
      store: store
    } do
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_execution_skip_carry")

      assert :ok = Storage.insert_execution(store, "execution-skip-carry", machine_state, :active)

      assert {:ok, %{position_blob: stored_blob}} =
               Storage.fetch_execution(store, "execution-skip-carry")

      assert is_binary(stored_blob)

      assert :ok =
               Storage.update_execution(store, "execution-skip-carry", machine_state, :failed,
                 position: :skip,
                 failure: "abandoned: operator request"
               )

      assert {:ok, updated} = Storage.fetch_execution(store, "execution-skip-carry")
      assert %{status: :failed, failure: "abandoned: operator request"} = updated
      assert updated.position_blob == stored_blob
    end

    # sabotage: two mutations together, because either layer alone
    # backstops the other - update_position_blob/4's :skip clause returning
    # {:ok, nil} without the fetch AND InMemory.update_execution/2 upserting on a
    # missing execution_id -> red, the update below returned :ok instead of
    # {:error, :execution_not_found}. Verified red, both reverted.
    test "update_execution/5 under position: :skip reports :execution_not_found for an unknown execution",
         %{
           store: store
         } do
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_execution_skip_missing")

      assert {:error, :execution_not_found} =
               Storage.update_execution(store, "execution-skip-missing", machine_state, :failed,
                 position: :skip
               )
    end
  end

  # -- Child listing: the facade arms Phase 1 adds (ADR-0008 decision 5) --

  describe "list_executions_by_metadata/2 and child_listing_supported?/1" do
    # sabotage: in Storage.child_listing_supported?/1, drop the
    # function_exported?/3 check and always return true -> red, this
    # assertion against NoLockAdapter (which exports no
    # list_executions_by_metadata/2) saw true instead of false. Verified red,
    # reverted.
    test "child_listing_supported?/1 answers both ways" do
      {:ok, supporting_store} = Storage.new(InMemory, [])
      {:ok, unsupporting_store} = Storage.new(NoLockAdapter, [])

      assert Storage.child_listing_supported?(supporting_store)
      refute Storage.child_listing_supported?(unsupporting_store)
    end

    # sabotage: in Storage.list_executions_by_metadata/2, drop the
    # child_listing_supported?/1 branch and always delegate to the adapter
    # -> red, this call against NoLockAdapter raised UndefinedFunctionError
    # instead of returning the refusal tuple. Verified red, reverted.
    test "returns {:error, :child_listing_unsupported} for an adapter that does not export the callback" do
      {:ok, store} = Storage.new(NoLockAdapter, [])

      assert {:error, :child_listing_unsupported} =
               Storage.list_executions_by_metadata(store, %{"tenant_id" => "acct_conformance"})
    end

    # sabotage: in Storage.list_executions_by_metadata/2, replace the delegation
    # with a hardcoded {:ok, []} -> red, the returned list below would come
    # back empty instead of naming the inserted execution. Verified red, reverted.
    test "delegates to the adapter for one that exports the callback" do
      {:ok, store} = Storage.new(InMemory, [])
      {_source, machine} = Charts.chart_a()

      machine_state =
        MachineState.new(machine, session_id: "sess_child_listing_delegate")

      metadata = %{"statifier_persistence" => %{"parent_execution_id" => "execution-parent"}}

      assert :ok =
               Storage.insert_execution(store, "execution-child-delegate", machine_state, :active,
                 metadata: metadata
               )

      assert {:ok, [record]} = Storage.list_executions_by_metadata(store, metadata)
      assert record.execution_id == "execution-child-delegate"
    end
  end

  # -- The fan-out facade arms (sp-t57, rulings C3 and C5) ---------------

  describe "the outcome payload and the status projection" do
    # sabotage: in Storage.execution_outcome_supported?/1, drop the
    # function_exported?/3 check and always call the adapter -> red, the
    # NoLockAdapter assertion raised UndefinedFunctionError instead of
    # answering false. Verified red, reverted.
    test "execution_outcome_supported?/1 and execution_states_supported?/1 answer both ways" do
      {:ok, supporting_store} = Storage.new(InMemory, [])
      {:ok, unsupporting_store} = Storage.new(NoLockAdapter, [])

      assert Storage.execution_outcome_supported?(supporting_store)
      assert Storage.execution_states_supported?(supporting_store)
      refute Storage.execution_outcome_supported?(unsupporting_store)
      refute Storage.execution_states_supported?(unsupporting_store)
    end

    # sabotage: in Storage.list_execution_states_by_metadata/2, drop the
    # execution_states_supported?/1 branch and always delegate -> red, this call
    # against NoLockAdapter raised UndefinedFunctionError instead of
    # returning the refusal tuple. Verified red, reverted.
    test "list_execution_states_by_metadata/2 refuses an adapter that does not export the callback" do
      {:ok, store} = Storage.new(NoLockAdapter, [])

      assert {:error, :execution_states_unsupported} =
               Storage.list_execution_states_by_metadata(store, %{
                 "tenant_id" => "acct_conformance"
               })
    end

    # sabotage: in Storage.update_execution_status/4, drop the outcome_blob key
    # from the record it builds -> red, the fetched record's outcome_blob
    # came back nil instead of the written payload. Verified red, reverted.
    test "update_execution_status/4 writes an outcome payload and a later status-only write keeps it" do
      {:ok, store} = Storage.new(InMemory, [])
      {_source, machine} = Charts.chart_a()
      machine_state = MachineState.new(machine, session_id: "sess_outcome_write")

      assert :ok =
               Storage.insert_execution(store, "execution-outcome-write", machine_state, :active)

      assert :ok =
               Storage.update_execution_status(store, "execution-outcome-write", :completed,
                 outcome_blob: <<7, 7>>
               )

      assert {:ok, %{outcome_blob: <<7, 7>>}} =
               Storage.fetch_execution(store, "execution-outcome-write")

      assert :ok =
               Storage.update_execution(
                 store,
                 "execution-outcome-write",
                 machine_state,
                 :completed
               )

      assert {:ok, %{outcome_blob: <<7, 7>>}} =
               Storage.fetch_execution(store, "execution-outcome-write")
    end
  end
end
