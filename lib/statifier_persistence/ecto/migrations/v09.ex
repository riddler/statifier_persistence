if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V09 do
    @moduledoc """
    V09 of the package DDL: a home for a durable subchart child's linkage
    outside `metadata` (ADR-0008's 2026-11-19 Amendment).

    Eight changes, one version:

    - six nullable columns on `executions`, one per value under the
      reserved linkage key (`StatifierPersistence.Execution.Linkage`):
      `linkage_parent_execution_id`, `linkage_invoke_id` and
      `linkage_content_hash` as `text`, `linkage_child_index` and
      `linkage_child_count` as `integer`, and `linkage_policy` as `text`;
    - a non-unique index on
      `executions(linkage_parent_execution_id, linkage_invoke_id)`, which
      serves the parent and the invocation matches;
    - a non-unique index on `executions(linkage_content_hash)`, which
      serves the pin count.

    The columns are what `StatifierPersistence.Storage.Ecto` writes a
    child's linkage into for a host that sets `linkage_columns: true` on
    `use StatifierPersistence.Ecto`, on a backend that cannot store
    `metadata`. They are plain scalars because equality on a scalar is SQL
    every Ecto backend parses, where the `jsonb` containment the
    `metadata` listings issue is not. On Postgres the linkage stays in
    `metadata` with the option on or off, and these columns stay `NULL`.

    A host that leaves `linkage_columns:` at `false` has an execution
    schema that names none of the six columns, so it may run this version
    or leave it: its adapter reads and writes exactly what it did before.
    A host that sets the option runs it before deploying the code that
    sets it.

    The version reads and writes no row. Every row that exists when it
    runs gets `NULL` in all six columns: nothing is backfilled, and a
    linkage already stored in `metadata` stays there and is read in place.

    Every change is one every backend has, so nothing here is guarded by
    adapter, and the version runs inside an ordinary transaction.
    `down/1` drops the two indexes and the six columns, and with them any
    linkage written into them.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @columns [
      linkage_parent_execution_id: :text,
      linkage_invoke_id: :text,
      linkage_child_index: :integer,
      linkage_content_hash: :text,
      linkage_child_count: :integer,
      linkage_policy: :text
    ]

    @doc """
    Adds the six linkage columns to `executions` and their two indexes,
    per `config`.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      executions = Config.table(config, :executions)

      alter table(executions, prefix: config.prefix) do
        for {name, type} <- @columns, do: add(name, type, null: true)
      end

      create(
        index(executions, [:linkage_parent_execution_id, :linkage_invoke_id],
          name: parent_index_name(executions),
          prefix: config.prefix
        )
      )

      create(
        index(executions, [:linkage_content_hash],
          name: content_hash_index_name(executions),
          prefix: config.prefix
        )
      )

      :ok
    end

    @doc """
    Drops the two linkage indexes and the six linkage columns.
    """
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      executions = Config.table(config, :executions)

      drop(
        index(executions, [:linkage_content_hash],
          name: content_hash_index_name(executions),
          prefix: config.prefix
        )
      )

      drop(
        index(executions, [:linkage_parent_execution_id, :linkage_invoke_id],
          name: parent_index_name(executions),
          prefix: config.prefix
        )
      )

      alter table(executions, prefix: config.prefix) do
        for {name, _type} <- Enum.reverse(@columns), do: remove(name)
      end

      :ok
    end

    # Named explicitly rather than left to Ecto's derivation, for V03's
    # reason: `down/1` has to drop the index `up/1` created, under a name
    # a reader of this module can check by eye.
    @spec parent_index_name(String.t()) :: atom()
    defp parent_index_name(executions), do: :"#{executions}_linkage_parent_index"

    @spec content_hash_index_name(String.t()) :: atom()
    defp content_hash_index_name(executions), do: :"#{executions}_linkage_content_hash_index"
  end
end
