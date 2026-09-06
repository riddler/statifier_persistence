if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V05 do
    @moduledoc """
    V05 of the package DDL: the per-run input log table (ADR-0010
    decision 9).

    Four columns beside the surrogate key: `run_id`, the run the entry
    belongs to; `seq`, its dense zero-based ordinal; `door`, the public
    door it entered by (`t:StatifierPersistence.Runs.entry/0`, as a
    string); and `input_blob`, the opaque payload the facade encoded above
    the adapter. `input_blob` is **nullable**, and a null is not "no
    value": it is decision 6's closed marker, written in the cap's last
    slot when a host-declared cap is reached.

    The unique index on `(run_id, seq)` is what makes denseness true.
    `StatifierPersistence.Storage.Ecto.append_input/3` takes its ordinal
    from the run's current maximum, under the exclusion the append already
    runs inside; a lost race then fails the write instead of duplicating an
    ordinal, because a gap in a log is a defect and a duplicate is a
    silently reordered replay. It doubles as the lookup index: every read
    of this table is one run's whole log in ascending `seq`, which the
    index serves directly.

    No foreign key to the runs table, for the same reason no other table
    here has one: `run_id` is a caller-supplied opaque string this layer
    stores verbatim (ADR-0002 decision 1), and a host's own retention of
    runs is not this package's to constrain.

    **Every backend, no Postgres-only spelling.** Unlike V03's `GIN`
    `jsonb_path_ops` index and V04's concurrent rebuild, there is nothing
    here a non-Postgres adapter cannot run: a table, four columns and a
    unique index. So this version carries no adapter check and no
    `@disable_ddl_transaction` recipe, and SQLite gets the input log on
    exactly the terms Postgres does (ADR-0010 decision 9).

    `down/1` drops the table, which is the whole of it: V05 adds nothing
    to a table another version owns.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc "Creates the input log table and its unique `(run_id, seq)` index."
    @spec up(Config.t()) :: :ok
    def up(%Config{key: {key_mod, key_opts}} = config) do
      inputs = Config.table(config, :inputs)

      create table(inputs, primary_key: false, prefix: config.prefix) do
        add(:id, key_mod.migration_type(key_opts), primary_key: true)
        add(:run_id, :text, null: false)
        add(:seq, :bigint, null: false)
        add(:door, :text, null: false)
        # Nullable by decision: a null blob is the closed marker of
        # ADR-0010 decision 6, never an absent payload.
        add(:input_blob, :binary, null: true)
        timestamps(type: :utc_datetime_usec)
      end

      create(unique_index(inputs, [:run_id, :seq], prefix: config.prefix))

      :ok
    end

    @doc "Drops the input log table."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      drop(table(Config.table(config, :inputs), prefix: config.prefix))

      :ok
    end
  end
end
