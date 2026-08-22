if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V01 do
    @moduledoc """
    V01 of the package DDL: the `charts`, `positions`, and `runs` tables
    per ADR-0002 (as amended) and the storage contract's field set
    (ADR-0003 decision 3).

    Table names, the surrogate primary key's column type, and the Postgres
    schema all come from the resolved `StatifierPersistence.Ecto.Config` -
    the same struct the generated schemas are built from. The engine
    identity columns (`content_hash`, `session_id`, `run_id`) are `text`
    with their unique indexes regardless of the configured key scheme:
    the identity guard never touches a surrogate key.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc "Creates the V01 tables and their unique indexes per `config`."
    @spec up(Config.t()) :: :ok
    def up(%Config{key: {key_mod, key_opts}} = config) do
      if config.prefix do
        execute(~s(CREATE SCHEMA IF NOT EXISTS "#{config.prefix}"))
      end

      pk_type = key_mod.migration_type(key_opts)

      charts = Config.table(config, :charts)

      create table(charts, primary_key: false, prefix: config.prefix) do
        add(:id, pk_type, primary_key: true)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:chart_blob, :binary, null: false)
        timestamps(type: :utc_datetime_usec)
      end

      create(unique_index(charts, [:content_hash], prefix: config.prefix))

      positions = Config.table(config, :positions)

      create table(positions, primary_key: false, prefix: config.prefix) do
        add(:id, pk_type, primary_key: true)
        add(:session_id, :text, null: false)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: false)
        timestamps(type: :utc_datetime_usec)
      end

      create(unique_index(positions, [:session_id], prefix: config.prefix))

      runs = Config.table(config, :runs)

      create table(runs, primary_key: false, prefix: config.prefix) do
        add(:id, pk_type, primary_key: true)
        add(:run_id, :text, null: false)
        add(:status, :text, null: false)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: true)
        add(:failure, :text, null: true)
        # Nullable by design (ADR-0002 decision 5): library code does not
        # populate it yet.
        add(:session_id, :text, null: true)
        timestamps(type: :utc_datetime_usec)
      end

      create(unique_index(runs, [:run_id], prefix: config.prefix))

      :ok
    end

    @doc "Drops the V01 tables in reverse creation order."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      for name <- [:runs, :positions, :charts] do
        drop(table(Config.table(config, name), prefix: config.prefix))
      end

      :ok
    end
  end
end
