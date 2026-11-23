defmodule StatifierPersistence.ExecutionsInheritedMetadataTest do
  @moduledoc """
  `StatifierPersistence.Executions.inherited_metadata/3` (ADR-0008's
  2026-11-23 Amendment, point 6) over the in-memory adapter and the Ecto
  adapter on Postgres, the two stores that keep host metadata. A child a
  driver created under `inherited_metadata_keys:` is read in
  `StatifierPersistence.DriverInheritedMetadataTest`, and the Ecto adapter
  off Postgres in `StatifierPersistence.Ecto.SqliteMigrationsTest`.

  The fixture is a loan whose records are stored directly: the loan holds
  a library host's own keys, the branch it belongs to and the patron who
  holds it, and its renewals carry the linkage a durable subchart child
  carries, one with the branch copied and one with nothing copied.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Machine, MachineState}
  alias StatifierPersistence.{EctoHosts, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage

  @renewal """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending">
    <state id="pending">
      <transition event="renewal.granted" target="granted"/>
    </state>
    <final id="granted"/>
  </scxml>
  """

  @loan "loan_copy_42"
  @host_metadata %{"branch_id" => "branch_east", "patron_id" => "patron_7"}

  setup %{adapter: adapter} do
    {:ok, machine} = Statifier.compile(@renewal)
    %{store: store(adapter), machine: machine, hash: Machine.identity(machine).content_hash}
  end

  # sabotage: answered the whole stored map from inherited_metadata/3 in
  # place of the named keys -> red, "patron_id" came back. Verified red,
  # reverted from a copy.
  test "a root answers the named keys it holds, with their values, and no other", ctx do
    insert(ctx, @loan, @host_metadata)

    assert {:ok, %{"branch_id" => "branch_east"} = named} =
             Executions.inherited_metadata(ctx.store, @loan, ["branch_id", "shelf_id"])

    assert map_size(named) == 1

    assert {:ok, @host_metadata} =
             Executions.inherited_metadata(ctx.store, @loan, ["branch_id", "patron_id"])

    assert {:ok, %{}} == Executions.inherited_metadata(ctx.store, @loan, [])
  end

  # sabotage: in inherited_metadata/3, read the parent's record when the
  # execution's linkage names one -> red, the renewal that copied nothing
  # answered the loan's keys. Verified red, reverted from a copy.
  test "a child answers what its own record holds, and the linkage is never walked", ctx do
    insert(ctx, @loan, @host_metadata)

    copied = Linkage.new(@loan, "renewal", 0, ctx.hash)
    bare = Linkage.new(@loan, "renewal_late", 0, ctx.hash)
    copied_id = insert_child(ctx, copied, %{"branch_id" => "branch_east"})
    bare_id = insert_child(ctx, bare, %{})

    assert {:ok, %{}} ==
             Executions.inherited_metadata(ctx.store, bare_id, ["branch_id", "patron_id"])

    assert {:ok, %{"branch_id" => "branch_east"} = named} =
             Executions.inherited_metadata(ctx.store, copied_id, ["branch_id", "patron_id"])

    assert map_size(named) == 1
  end

  # sabotage: answered `{:ok, %{}}` from inherited_metadata/3 when the read
  # failed -> red, the not-found never arrived. Verified red, reverted from
  # a copy.
  test "an execution that is not stored answers the read's error", ctx do
    assert {:error, :execution_not_found} =
             Executions.inherited_metadata(ctx.store, "loan_copy_never_stored", ["branch_id"])
  end

  # sabotage: dropped the reserved-key check from inherited_metadata/3 ->
  # red, the stored linkage came back in place of the raise. Verified red,
  # reverted from a copy.
  test "naming the reserved key raises, stored or not", ctx do
    child_id = insert_child(ctx, Linkage.new(@loan, "renewal", 0, ctx.hash), %{})

    for id <- [child_id, "loan_copy_never_stored"] do
      assert_raise ArgumentError, ~r/reserved/, fn ->
        Executions.inherited_metadata(ctx.store, id, ["branch_id", Linkage.reserved_key()])
      end
    end
  end

  defp insert(ctx, id, metadata) do
    machine_state = MachineState.new(ctx.machine, session_id: "sess_" <> id)
    :ok = Storage.insert_execution(ctx.store, id, machine_state, :active, metadata: metadata)
    id
  end

  defp insert_child(ctx, %Linkage{} = linkage, inherited) do
    id =
      Linkage.child_execution_id(
        linkage.parent_execution_id,
        linkage.invoke_id,
        linkage.child_index
      )

    insert(ctx, id, Map.merge(inherited, Linkage.to_metadata(linkage)))
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
end

defmodule StatifierPersistence.ExecutionsInheritedMetadataDoctest do
  use ExUnit.Case, async: true

  # sabotage: answered the whole stored map from inherited_metadata/3 ->
  # red, the doctest printed "patron_id" too. Verified red, reverted from a
  # copy.
  doctest StatifierPersistence.Executions, only: [inherited_metadata: 3]
end
