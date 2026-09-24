if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V08 do
    @moduledoc """
    V08 of the package DDL: when an execution ended.

    Two changes, one version:

    - `ended_at`, a nullable `utc_datetime_usec` on `executions`, the
      type V07 gives `retired_at` on `charts`;
    - a non-unique index on `executions(ended_at)`.

    `ended_at` is written once, when an execution first reaches a terminal
    status, and never again: `c:StatifierPersistence.Storage.Adapter.update_execution/2`
    keeps a stored stamp over whatever the record it is given carries.
    Before this version the only time an executions row carried was
    `updated_at`, which any later write moves, so "how long has this
    execution been finished" had no column that answered it and kept
    answering it. The index is what a query over that column needs to
    avoid a sequential scan of the whole executions table.

    Every row that exists when this version runs gets a `NULL`, terminal
    rows included: the version adds a column and backfills nothing, because
    the time a row that is already terminal ended is not stored anywhere
    to copy from. The stamp is written on the transition into a terminal
    status, and such a row made that transition before the column existed.

    Both changes are ones every backend has, so nothing here is guarded
    by adapter, and the version runs inside an ordinary transaction.
    `down/1` drops the index and the column, stamps and all.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc """
    Adds `ended_at` to `executions` and indexes it, per `config`.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      executions = Config.table(config, :executions)

      alter table(executions, prefix: config.prefix) do
        add(:ended_at, :utc_datetime_usec, null: true)
      end

      create(
        index(executions, [:ended_at],
          name: ended_at_index_name(executions),
          prefix: config.prefix
        )
      )

      :ok
    end

    @doc """
    Drops the `executions(ended_at)` index and the column.
    """
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      executions = Config.table(config, :executions)

      drop(
        index(executions, [:ended_at],
          name: ended_at_index_name(executions),
          prefix: config.prefix
        )
      )

      alter table(executions, prefix: config.prefix) do
        remove(:ended_at)
      end

      :ok
    end

    # Named explicitly rather than left to Ecto's derivation, for V03's
    # reason: `down/1` has to drop the index `up/1` created, under a name
    # a reader of this module can check by eye.
    @spec ended_at_index_name(String.t()) :: atom()
    defp ended_at_index_name(executions), do: :"#{executions}_ended_at_index"
  end
end
