defmodule StatifierPersistence.Storage.EctoLinkageColumnsTest do
  @moduledoc """
  The `linkage_columns:` option on Postgres (ADR-0008's 2026-11-19
  Amendment). On this backend the option changes the generated schema and
  nothing else: a durable child's linkage stays under the reserved key in
  the `jsonb` `metadata` column, byte for byte, and the store declares no
  separate linkage support. `Default` leaves the option at its default and
  `Linked` sets it, over the same tables; the bootstrap's migration 112
  gives those tables V09's columns. The SQLite half, where the option moves
  the linkage into the columns, is in
  `StatifierPersistence.Ecto.SqliteMigrationsTest`.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.EctoHosts.{Default, Linked}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)

    {:ok, default} = Storage.new(Storage.Ecto, persistence: Default)
    {:ok, linked} = Storage.new(Storage.Ecto, persistence: Linked)

    %{default: default, linked: linked}
  end

  # sabotage: made the generated execution schema name the linkage columns
  # whatever the option -> red here on the schema's fields. Verified red,
  # reverted from a copy.
  test "a host that changes nothing stores a linkage in jsonb and answers as before",
       %{default: store} do
    parent = "execution_loan_pg_off"
    linkage = Linkage.new(parent, "renewals", 0, "sha256:loan-pg-off")
    child = Linkage.child_execution_id(parent, "renewals", 0)

    refute Storage.Ecto.supports_linkage?(store.opts)
    refute Storage.linkage_supported?(store)
    assert Storage.metadata_supported?(store)
    refute Enum.any?(Default.Execution.__schema__(:fields), &linkage_field?/1)

    :ok =
      Storage.Ecto.insert_execution(
        store.opts,
        record(child, %{metadata: Linkage.to_metadata(linkage)})
      )

    assert stored_metadata(child) == Linkage.to_metadata(linkage)

    assert {:ok, [%{execution_id: ^child}]} =
             Storage.Ecto.list_executions_by_metadata(store.opts, Linkage.parent_match(parent))
  end

  # sabotage: dropped the Postgres conjunct from Storage.Ecto's
  # linkage_columns?/1 -> red here on `refute supports_linkage?`. Verified
  # red, reverted from a copy.
  test "a Postgres host that sets the option keeps the linkage in jsonb and its columns empty",
       %{linked: store} do
    parent = "execution_loan_pg_on"
    pin = "sha256:loan-pg-on"
    linkage = Linkage.new(parent, "renewals", 0, pin, 2, :all)
    child = Linkage.child_execution_id(parent, "renewals", 0)

    refute Storage.Ecto.supports_linkage?(store.opts)
    refute Storage.linkage_supported?(store)
    assert Storage.metadata_supported?(store)
    assert Enum.count(Linked.Execution.__schema__(:fields), &linkage_field?/1) == 6

    :ok = Storage.Ecto.insert_execution(store.opts, record(parent))

    :ok =
      Storage.Ecto.insert_execution(
        store.opts,
        record(child, %{metadata: Linkage.to_metadata(linkage)})
      )

    assert stored_metadata(child) == Linkage.to_metadata(linkage)

    assert %{rows: [[nil, nil, nil, nil, nil, nil]]} =
             SQL.query!(
               TestRepo,
               "SELECT linkage_parent_execution_id, linkage_invoke_id, linkage_child_index, " <>
                 "linkage_content_hash, linkage_child_count, linkage_policy " <>
                 "FROM statifier_executions WHERE execution_id = $1",
               [child]
             )

    assert {:ok, [%{execution_id: ^child, child_index: 0}]} =
             Storage.Ecto.list_execution_states_by_metadata(
               store.opts,
               Linkage.invocation_match(parent, "renewals")
             )

    assert {:ok, %{children: 1}} = Storage.Ecto.count_executions_by_content_hash(store.opts, pin)

    :ok =
      Storage.Ecto.write_tree_migration(store.opts, [
        {:repin, record(child), "sha256:loan-pg-on-new"}
      ])

    assert {:ok, %Linkage{content_hash: "sha256:loan-pg-on-new"}} =
             child |> stored_metadata() |> Linkage.from_metadata()
  end

  # sabotage: made Storage.linkage_supported?/1 answer true for every store
  # -> red here. Verified red, reverted from a copy.
  test "an adapter that does not export the callback declares no linkage" do
    {:ok, store} = Storage.new(InMemory, [])

    refute function_exported?(InMemory, :supports_linkage?, 1)
    refute Storage.linkage_supported?(store)
  end

  defp record(execution_id, overrides \\ %{}) do
    Map.merge(
      %{
        execution_id: execution_id,
        status: :active,
        content_hash: "sha256:loan-pg-chart",
        identity_blob: <<1, 2, 3>>,
        position_blob: <<7, 8, 9>>,
        failure: nil,
        metadata: %{},
        outcome_blob: nil,
        ended_at: nil
      },
      overrides
    )
  end

  defp stored_metadata(execution_id) do
    %{rows: [[metadata]]} =
      SQL.query!(
        TestRepo,
        "SELECT metadata FROM statifier_executions WHERE execution_id = $1",
        [execution_id]
      )

    metadata
  end

  defp linkage_field?(field), do: field |> Atom.to_string() |> String.starts_with?("linkage_")
end
