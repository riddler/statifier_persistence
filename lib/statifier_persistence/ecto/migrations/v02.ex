if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V02 do
    @moduledoc """
    V02 of the package DDL: the nullable `metadata` `jsonb` column on the
    runs table (ADR-0006 decision 3, decision 4's migration shape).

    Nullable, because a run created with no metadata stores none, and
    ADR-0006 decision 3 makes the empty map the never-refused default -
    a `NOT NULL` column would turn "no metadata" into a write this package
    would have to invent a value for.

    **No index.** Which key/value pairs a host queries by, and therefore
    which expression or GIN index it wants, is the host's call and not
    something this package can guess (ADR-0006 decision 4). A host that
    queries the column at any volume adds its own index in its own
    migration; `StatifierPersistence.Storage.Ecto.list_runs_by_metadata/2`
    issues a `jsonb` containment query a GIN index on the column serves
    directly.

    `:blob_type` does not reach this column and never will: it is a
    queryable column, not a blob, which is exactly why ADR-0006 decision 2
    admits host identities into it and nothing else.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc "Adds the runs table's nullable `metadata` jsonb column per `config`."
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      alter table(Config.table(config, :runs), prefix: config.prefix) do
        add(:metadata, :map, null: true)
      end

      :ok
    end

    @doc "Drops the runs table's `metadata` column."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      alter table(Config.table(config, :runs), prefix: config.prefix) do
        remove(:metadata)
      end

      :ok
    end
  end
end
