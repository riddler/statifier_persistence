if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V01 do
    @moduledoc """
    V01 of the package DDL: the `charts`, `positions`, and `executions` tables
    per ADR-0002 (as amended) and the storage contract's field set
    (ADR-0003 decision 3).

    Table names, the surrogate primary key's column type, and the Postgres
    schema all come from the resolved `StatifierPersistence.Ecto.Config` -
    the same struct the generated schemas are built from. The engine
    identity columns (`content_hash`, `session_id`, `execution_id`) are `text`
    with their unique indexes regardless of the configured key scheme:
    the identity guard never touches a surrogate key.

    This migration always emits `:binary` (`bytea`) for the three blob
    columns (`identity_blob`, `chart_blob`, `position_blob`) and does
    not read `Config`'s `:blob_type` option. A custom `:blob_type` whose
    underlying database type is still binary (an envelope-encrypting
    type that dumps to and loads from raw bytes, for example) needs no
    DDL change - this migration already matches it. A `:blob_type` that
    dumps to a different underlying type (text, jsonb, a Postgres
    domain) needs the host to alter those three columns itself; this
    helper does not do it for them.

    Each of the three tables carries the host's `:leading_columns`, if it
    configured any, immediately after `id` and in the order given - the
    one place a column the host owns can sit at a fixed ordinal position,
    since a column a later `ALTER TABLE` adds lands at the end. They are
    added as configured and nothing more: a default or a `NOT NULL` is a
    later migration of the host's own.

    Two further options shape these three tables and nothing else. Under
    `timestamps_position: :leading` the `inserted_at` / `updated_at` pair
    follows the leading columns instead of closing each table, and
    `:column_collations` gives a text column declared here the collation
    named for it. Both exist so a host that once wrote these tables by
    hand can be matched column for column; the default for each is the
    layout above, unchanged.
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
        add_leading_columns(config)
        add(:content_hash, :text, collated(config, :content_hash, null: false))
        add(:identity_blob, :binary, null: false)
        add(:chart_blob, :binary, null: false)
        add_trailing_timestamps(config)
      end

      create(unique_index(charts, [:content_hash], prefix: config.prefix))

      positions = Config.table(config, :positions)

      create table(positions, primary_key: false, prefix: config.prefix) do
        add(:id, pk_type, primary_key: true)
        add_leading_columns(config)
        add(:session_id, :text, collated(config, :session_id, null: false))
        add(:content_hash, :text, collated(config, :content_hash, null: false))
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: false)
        add_trailing_timestamps(config)
      end

      create(unique_index(positions, [:session_id], prefix: config.prefix))

      executions = Config.table(config, :executions)

      create table(executions, primary_key: false, prefix: config.prefix) do
        add(:id, pk_type, primary_key: true)
        add_leading_columns(config)
        add(:execution_id, :text, collated(config, :execution_id, null: false))
        add(:status, :text, collated(config, :status, null: false))
        add(:content_hash, :text, collated(config, :content_hash, null: false))
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: true)
        add(:failure, :text, collated(config, :failure, null: true))
        # Nullable by design (ADR-0002 decision 5): library code does not
        # populate it yet.
        add(:session_id, :text, collated(config, :session_id, null: true))
        add_trailing_timestamps(config)
      end

      create(unique_index(executions, [:execution_id], prefix: config.prefix))

      :ok
    end

    # Called inside each `create table` block, right after `id`: `add/3`
    # appends to the table being created, so these land at positions 2..n,
    # followed by the timestamp pair when it is configured to lead.
    defp add_leading_columns(%Config{leading_columns: columns} = config) do
      for {name, {type, opts}} <- columns, do: add(name, type, opts)

      if config.timestamps_position == :leading, do: timestamps(type: :utc_datetime_usec)
    end

    # Called last inside each `create table` block: the package's layout
    # unless the timestamp pair already went in with the leading columns.
    defp add_trailing_timestamps(%Config{timestamps_position: position}) do
      if position == :trailing, do: timestamps(type: :utc_datetime_usec)
    end

    # The `add/3` opts for a package text column, carrying the collation
    # `:column_collations` names for it, if any.
    defp collated(%Config{column_collations: collations}, name, opts) do
      case Keyword.fetch(collations, name) do
        {:ok, collation} -> Keyword.put(opts, :collation, collation)
        :error -> opts
      end
    end

    @doc "Drops the V01 tables in reverse creation order."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      for name <- [:executions, :positions, :charts] do
        drop(table(Config.table(config, name), prefix: config.prefix))
      end

      :ok
    end
  end
end
