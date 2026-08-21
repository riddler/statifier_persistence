defmodule StatifierPersistence.StorageTest do
  use ExUnit.Case, async: true

  alias Statifier.{Machine, MachineState}
  alias Statifier.Machine.Identity
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Testing.Charts

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  defp machine_state_for(machine, session_id) do
    MachineState.new(machine, session_id: session_id, datamodel: %{"count" => 1})
  end

  # sabotage: in `Storage.save_position/3`, replace the
  # `store.adapter.save_position(store.opts, position_record)` call with a
  # bare `:ok` that never writes -> red, `load_position/3` then returns
  # `{:error, :position_not_found}` instead of the round-tripped state.
  # Verified red, reverted.
  test "round trip: save a position and load it back with the same machine", %{store: store} do
    {_source, machine} = Charts.chart_a()
    machine_state = machine_state_for(machine, "sess_round_trip")

    assert :ok = Storage.save_position(store, "sess_round_trip", machine_state)

    assert {:ok, loaded} = Storage.load_position(store, "sess_round_trip", machine)
    assert loaded.configuration == machine_state.configuration
    assert loaded.datamodel == machine_state.datamodel
    assert loaded.invoke_counter == machine_state.invoke_counter
    assert loaded.send_counter == machine_state.send_counter
    assert loaded.timer_counter == machine_state.timer_counter
    assert loaded.macrostep == machine_state.macrostep
    assert loaded.microstep == machine_state.microstep
    assert loaded.round == machine_state.round
    assert loaded.status == machine_state.status
    assert loaded.running == machine_state.running
  end

  # sabotage: this is the guard test the plan's Success Criteria names
  # explicitly. In `Storage.load_position/3`, replace the whole `with`
  # (fetch -> precheck_identity/2 -> `Position.from_binary/2`) with a body
  # that fetches the position record and then unconditionally returns
  # `{:ok, MachineState.new(machine)}`, skipping the identity check
  # entirely and returning a "decoded" state anyway -> red, this test
  # asserted a returned `{:ok, _}` instead of the expected
  # `{:error, {:identity_mismatch, _, _}}` tuple. Verified red, reverted.
  test "the mismatch: loading against a different chart revision is refused, not raised", %{
    store: store
  } do
    {_source_a, machine_a} = Charts.chart_a()
    {_source_b, machine_b} = Charts.chart_b()

    assert Identity.matches?(Machine.identity(machine_a), Machine.identity(machine_b)) == false

    machine_state = machine_state_for(machine_a, "sess_mismatch")
    assert :ok = Storage.save_position(store, "sess_mismatch", machine_state)

    assert {:error, {:identity_mismatch, expected, actual}} =
             Storage.load_position(store, "sess_mismatch", machine_b)

    assert %Identity{} = expected
    assert %Identity{} = actual
    assert expected.content_hash != actual.content_hash
    assert expected.content_hash == Machine.identity(machine_a).content_hash
    assert actual.content_hash == Machine.identity(machine_b).content_hash
  end

  # sabotage: same mutation as the mismatch test above (skip the identity
  # check and unconditionally return `{:ok, MachineState.new(machine)}` from
  # `load_position/3`) -> red, this test's corrupt `position_blob` stopped
  # being refused; it asserted `{:ok, _}` instead of
  # `{:error, :not_a_statifier_blob}`. Verified red, reverted.
  test "corrupt position bytes are refused as :not_a_statifier_blob, not raised", %{
    store: store
  } do
    {_source, machine} = Charts.chart_a()
    identity = Machine.identity(machine)

    corrupt_record = %{
      session_id: "sess_corrupt",
      content_hash: identity.content_hash,
      identity_blob: Identity.to_binary(identity),
      position_blob: "not a statifier position blob"
    }

    :ok = InMemory.save_position(store.opts, corrupt_record)

    assert {:error, :not_a_statifier_blob} =
             Storage.load_position(store, "sess_corrupt", machine)
  end

  # sabotage: in `Storage.load_position/3`'s private `precheck_identity/2`,
  # delete the `%Machine{identity: nil} -> {:error, :unidentified_chart}`
  # clause, leaving only the `Identity.from_binary/1` + `matches?/2` clause
  # -> red, `Identity.matches?/2` is total and reached the mismatch arm with
  # a `nil` supplied identity, so this test's returned error changed from
  # `:unidentified_chart` to an `:identity_mismatch` tuple. Verified red,
  # reverted.
  test "loading with an unidentified machine is refused as :unidentified_chart", %{
    store: store
  } do
    {_source, machine} = Charts.chart_a()
    machine_state = machine_state_for(machine, "sess_unidentified_load")
    assert :ok = Storage.save_position(store, "sess_unidentified_load", machine_state)

    unidentified_machine = Charts.unidentified_machine()

    assert {:error, :unidentified_chart} =
             Storage.load_position(store, "sess_unidentified_load", unidentified_machine)
  end

  # sabotage: in `Storage.save_position/3`, delete the
  # `Machine.identity(machine_state.machine) -> nil -> {:error, :unidentified_chart}`
  # clause, falling back to a dummy identity and encoding the record with
  # `:erlang.term_to_binary/1` directly instead of `Position.to_binary/1`
  # (bypassing that function's own guard too) -> red, this test's assertion
  # that saving is refused failed (`save_position/3` returned `:ok`), which
  # also means the "nothing is written" assertion below it would have gone
  # red too. Verified red, reverted.
  test "saving a position for an unidentified machine is refused, and nothing is written", %{
    store: store
  } do
    unidentified_machine = Charts.unidentified_machine()
    machine_state = machine_state_for(unidentified_machine, "sess_unidentified_save")

    assert {:error, :unidentified_chart} =
             Storage.save_position(store, "sess_unidentified_save", machine_state)

    assert {:error, :position_not_found} =
             Storage.load_position(store, "sess_unidentified_save", unidentified_machine)
  end

  # sabotage: in `StatifierPersistence.Storage.InMemory.fetch_position/2`,
  # change the `nil -> {:error, :position_not_found}` clause to return
  # `{:ok, a_placeholder_record}` instead -> red, `load_position/3` then hit
  # the placeholder's empty `position_blob` and returned
  # `{:error, :not_a_statifier_blob}` rather than `:position_not_found`.
  # Verified red, reverted (adapter left unchanged otherwise).
  test "loading an unknown session id returns :position_not_found", %{store: store} do
    {_source, machine} = Charts.chart_a()

    assert {:error, :position_not_found} =
             Storage.load_position(store, "sess_never_saved", machine)
  end

  # sabotage: in `Storage.save_chart/3`, replace the
  # `store.adapter.save_chart(store.opts, chart_record)` call with a bare
  # `:ok` that never writes -> red, the subsequent `fetch_chart/2` returned
  # `{:error, :chart_not_found}` instead of the saved record. Verified red,
  # reverted.
  test "fetch_chart round trips a saved chart record", %{store: store} do
    {source, machine} = Charts.chart_a()

    assert :ok = Storage.save_chart(store, machine, source)

    content_hash = Machine.identity(machine).content_hash
    assert {:ok, chart_record} = Storage.fetch_chart(store, content_hash)
    assert chart_record.chart_blob == source
    assert chart_record.content_hash == content_hash
  end

  # sabotage: in `Storage.save_chart/3`, delete the
  # `Machine.identity(machine) -> nil -> {:error, :unidentified_chart}`
  # clause, falling back to a dummy identity so the write proceeds anyway
  # -> red, this test's assertion that saving is refused failed
  # (`save_chart/3` returned `:ok`). Verified red, reverted.
  test "saving a chart for an unidentified machine is refused, and nothing is written", %{
    store: store
  } do
    unidentified_machine = Charts.unidentified_machine()

    assert {:error, :unidentified_chart} =
             Storage.save_chart(store, unidentified_machine, "source bytes")
  end
end
