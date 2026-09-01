defmodule StatifierPersistence.Storage.EctoMetadataTest do
  @moduledoc """
  ADR-0006 decision 3's Ecto arm: the V02 `jsonb` column, the
  equality-match list helper, and the refusal of a value `jsonb` cannot
  hold.

  The conformance suite already proves the round trip through the adapter.
  What this module adds is what only the Ecto adapter can be asked: that
  the empty map is stored as `NULL` in the real column, that the list
  helper matches on all pairs and nothing looser, and that a
  non-JSON-representable term is refused at open rather than raising from
  the encoder or being stored as something else.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.MachineState
  alias StatifierPersistence.Ecto.Config
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Testing.Charts
  alias StatifierPersistence.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default, sandbox: false)
    {_source, machine} = Charts.chart_a()

    machine_state = MachineState.new(machine, session_id: "sess_ecto_metadata")

    %{store: store, machine_state: machine_state}
  end

  defp runs_table, do: Config.table(Default.__statifier_persistence__(:config), :runs)

  defp insert(store, machine_state, run_id, metadata) do
    Storage.insert_run(store, run_id, machine_state, :active, metadata: metadata)
  end

  # sabotage: in Storage.Ecto's encode_metadata/1, return the map unchanged
  # for the empty case (drop the map_size == 0 clause) -> red, the raw
  # column held {} instead of NULL. Verified red, reverted.
  test "the empty map is stored as SQL NULL and reads back as %{}", %{
    store: store,
    machine_state: machine_state
  } do
    assert :ok = insert(store, machine_state, "run-ecto-md-empty", %{})

    %{rows: [[raw]]} =
      TestRepo.query!("SELECT metadata FROM #{runs_table()} WHERE run_id = $1", [
        "run-ecto-md-empty"
      ])

    assert raw == nil
    assert {:ok, record} = Storage.fetch_run(store, "run-ecto-md-empty")
    assert record.metadata == %{}
  end

  # sabotage: in Storage.Ecto's do_insert_run/3, drop the metadata from the
  # struct/3 call so the column is never written -> red, the raw column
  # held NULL instead of the two pairs. Verified red, reverted.
  test "a non-empty map lands in the jsonb column verbatim", %{
    store: store,
    machine_state: machine_state
  } do
    metadata = %{"tenant_id" => "acct_01H8X", "processor_account_id" => "pacct_4471"}

    assert :ok = insert(store, machine_state, "run-ecto-md-full", metadata)

    %{rows: [[raw]]} =
      TestRepo.query!("SELECT metadata FROM #{runs_table()} WHERE run_id = $1", [
        "run-ecto-md-full"
      ])

    assert raw == metadata
  end

  describe "list_runs_by_metadata/2" do
    # sabotage: in Storage.Ecto.list_runs_by_metadata/2, replace the `@>`
    # containment fragment with `?->>key = value` on the first pair only ->
    # red, the two-pair query matched the run that shares only tenant_id,
    # so the returned id list had two entries instead of one. Verified red,
    # reverted.
    test "matches every given pair, and nothing looser", %{
      store: store,
      machine_state: machine_state
    } do
      :ok = insert(store, machine_state, "run-ls-a", %{"tenant_id" => "t1", "acct" => "a1"})
      :ok = insert(store, machine_state, "run-ls-b", %{"tenant_id" => "t1", "acct" => "a2"})
      :ok = insert(store, machine_state, "run-ls-c", %{"tenant_id" => "t2", "acct" => "a1"})
      :ok = insert(store, machine_state, "run-ls-d", %{})

      assert {:ok, both} =
               Storage.Ecto.list_runs_by_metadata(store.opts, %{
                 "tenant_id" => "t1",
                 "acct" => "a1"
               })

      assert Enum.map(both, & &1.run_id) == ["run-ls-a"]

      assert {:ok, tenant} =
               Storage.Ecto.list_runs_by_metadata(store.opts, %{"tenant_id" => "t1"})

      assert Enum.sort(Enum.map(tenant, & &1.run_id)) == ["run-ls-a", "run-ls-b"]
    end

    # sabotage: in Storage.Ecto.list_runs_by_metadata/2, build the returned
    # maps inline without decode_status/1 (carry row.status through as the
    # stored string) -> red, the returned record's status was "active"
    # rather than :active. Verified red, reverted.
    test "returns records in fetch_run/2's shape", %{store: store, machine_state: machine_state} do
      metadata = %{"tenant_id" => "t-shape"}
      :ok = insert(store, machine_state, "run-ls-shape", metadata)

      assert {:ok, [record]} = Storage.Ecto.list_runs_by_metadata(store.opts, metadata)
      assert {:ok, ^record} = Storage.fetch_run(store, "run-ls-shape")
      assert record.status == :active
      assert record.metadata == metadata
    end

    # sabotage: in Storage.Ecto's validate_match!/1, delete the
    # map_size(metadata) > 0 guard so the empty map falls through to the
    # query -> red, no ArgumentError was raised and every run with any
    # metadata came back. Verified red, reverted.
    test "refuses an empty map rather than matching every run", %{store: store} do
      assert_raise ArgumentError, ~r/non-empty map/, fn ->
        Storage.Ecto.list_runs_by_metadata(store.opts, %{})
      end
    end
  end

  describe "values jsonb cannot hold" do
    # sabotage: in Storage.Ecto.insert_run/2, drop the
    # json_representable?/1 branch and always call do_insert_run/3 -> red,
    # the insert raised Protocol.UndefinedError from the JSON encoder
    # instead of returning {:error, :metadata_unsupported}. Verified red,
    # reverted.
    test "a tuple value is refused at open, and nothing is written", %{
      store: store,
      machine_state: machine_state
    } do
      assert {:error, :metadata_unsupported} =
               insert(store, machine_state, "run-ecto-md-tuple", %{"pair" => {1, 2}})

      assert {:error, :run_not_found} = Storage.fetch_run(store, "run-ecto-md-tuple")
    end

    # sabotage: same mutation as above -> red for the same reason with a
    # value that is a binary but not valid UTF-8, which Postgres rejects
    # for jsonb. Verified red, reverted.
    test "a non-UTF-8 binary value is refused at open", %{
      store: store,
      machine_state: machine_state
    } do
      assert {:error, :metadata_unsupported} =
               insert(store, machine_state, "run-ecto-md-bytes", %{"raw" => <<0xFF, 0xFE>>})
    end

    # sabotage: in Storage.Ecto's json_representable?/1, add a clause
    # accepting is_atom(value) -> red, the atom was stored and read back as
    # the string "pending", a different term than went in - the silent
    # substitution the refusal exists to prevent. Verified red, reverted.
    test "an atom value is refused at open rather than being stringified", %{
      store: store,
      machine_state: machine_state
    } do
      assert {:error, :metadata_unsupported} =
               insert(store, machine_state, "run-ecto-md-atom", %{"state" => :pending})
    end

    # sabotage: in Storage.Ecto's json_representable?/1, make the map
    # clause accept any key type -> red, the nested atom-keyed map was
    # stored and read back with string keys. Verified red, reverted.
    test "a nested map with non-string keys is refused at open", %{
      store: store,
      machine_state: machine_state
    } do
      assert {:error, :metadata_unsupported} =
               insert(store, machine_state, "run-ecto-md-nested", %{"nested" => %{a: 1}})
    end

    # sabotage: in Storage.Ecto's json_representable?/1, return false for
    # is_list values -> red, this nested list of strings was refused and
    # the insert returned {:error, :metadata_unsupported} instead of :ok.
    # Verified red, reverted.
    test "nested JSON-representable values are accepted and round-trip", %{
      store: store,
      machine_state: machine_state
    } do
      metadata = %{"tags" => ["a", "b"], "counts" => %{"n" => 2}, "flag" => true, "none" => nil}

      assert :ok = insert(store, machine_state, "run-ecto-md-nested-ok", metadata)
      assert {:ok, record} = Storage.fetch_run(store, "run-ecto-md-nested-ok")
      assert record.metadata == metadata
    end
  end

  describe "StatifierPersistence.Run.Linkage's reserved namespace (sp-nt8, ADR-0008)" do
    # sabotage: Linkage.to_metadata/1's child_index emitted as an atom
    # (`child_index: 0` instead of `"child_index" => 0`) -> red, the insert
    # returned {:error, :metadata_unsupported} because an atom key is not
    # `jsonb`-representable. Verified red, reverted.
    test "the reserved linkage namespace is jsonb-representable and round-trips", %{
      store: store,
      machine_state: machine_state
    } do
      linkage = Linkage.new("run_parent", "call", 0, "sha256:child")
      metadata = Linkage.to_metadata(linkage)

      assert :ok = insert(store, machine_state, "run-ecto-linkage", metadata)
      assert {:ok, record} = Storage.fetch_run(store, "run-ecto-linkage")
      assert record.metadata == metadata
      assert {:ok, ^linkage} = Linkage.from_metadata(record.metadata)
    end
  end
end
