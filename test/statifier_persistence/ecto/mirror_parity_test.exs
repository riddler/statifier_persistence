defmodule StatifierPersistence.Ecto.MirrorParityTest do
  # A host that wrote V01's and V05's tables by hand wants to swap that
  # migration for the helper at the same migration version. This module
  # proves the swap: the helper, configured with the host's layout, builds
  # the same catalog the hand-written mirror below builds. Live DDL outside
  # the SQL sandbox, like leading_columns_test.exs: the module switches the
  # repo to :auto for its own tables and restores :manual on exit, hence
  # async: false.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierPersistence.Ecto.Config
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.TestRepo

  # The host's layout: its own column right after id, the timestamp pair
  # right after that, and execution_id declared COLLATE "C".
  defmodule ParityHost do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      table_prefix: "mp_pkg_",
      leading_columns: [tenant_id: {:text, null: true}],
      timestamps_position: :leading,
      column_collations: [execution_id: "C"]
  end

  # The same package with every layout option left at its default.
  defmodule DefaultLayoutHost do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      table_prefix: "mp_def_"
  end

  defmodule MigrateParityHost do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.Ecto.MirrorParityTest.ParityHost)
    def down, do: Migrations.down(for: StatifierPersistence.Ecto.MirrorParityTest.ParityHost)
  end

  defmodule MigrateDefaultLayoutHost do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.Ecto.MirrorParityTest.DefaultLayoutHost)

    def down,
      do: Migrations.down(for: StatifierPersistence.Ecto.MirrorParityTest.DefaultLayoutHost)
  end

  # The hand-written mirror: V01's three tables and V05's input log
  # written out column by column in the host's layout, with the package's
  # own V02-V04 and V06-V07 run between and after them exactly where the
  # helper runs them, so the columns those versions append land at the
  # same ordinal positions on both sides.
  defmodule MigrateHandMirror do
    use Ecto.Migration

    @prefix "mp_mir_"

    def up do
      create table(:mp_mir_charts, primary_key: false) do
        add(:id, :text, primary_key: true)
        add(:tenant_id, :text, null: true)
        timestamps(type: :utc_datetime_usec)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:chart_blob, :binary, null: false)
      end

      create(unique_index(:mp_mir_charts, [:content_hash]))

      create table(:mp_mir_positions, primary_key: false) do
        add(:id, :text, primary_key: true)
        add(:tenant_id, :text, null: true)
        timestamps(type: :utc_datetime_usec)
        add(:session_id, :text, null: false)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: false)
      end

      create(unique_index(:mp_mir_positions, [:session_id]))

      create table(:mp_mir_executions, primary_key: false) do
        add(:id, :text, primary_key: true)
        add(:tenant_id, :text, null: true)
        timestamps(type: :utc_datetime_usec)
        add(:execution_id, :text, null: false, collation: "C")
        add(:status, :text, null: false)
        add(:content_hash, :text, null: false)
        add(:identity_blob, :binary, null: false)
        add(:position_blob, :binary, null: true)
        add(:failure, :text, null: true)
        add(:session_id, :text, null: true)
      end

      create(unique_index(:mp_mir_executions, [:execution_id]))

      Migrations.up(
        repo: StatifierPersistence.TestRepo,
        table_prefix: @prefix,
        from: 2,
        version: 4
      )

      create table(:mp_mir_inputs, primary_key: false) do
        add(:id, :text, primary_key: true)
        add(:tenant_id, :text, null: true)
        timestamps(type: :utc_datetime_usec)
        add(:execution_id, :text, null: false, collation: "C")
        add(:seq, :bigint, null: false)
        add(:door, :text, null: false)
        add(:input_blob, :binary, null: true)
      end

      create(unique_index(:mp_mir_inputs, [:execution_id, :seq]))

      Migrations.up(repo: StatifierPersistence.TestRepo, table_prefix: @prefix, from: 6)
    end
  end

  @parity_version 20_260_924_000_001
  @mirror_version 20_260_924_000_002
  @default_version 20_260_924_000_003

  @kinds ["charts", "executions", "inputs", "positions"]
  @prefixes ["mp_pkg_", "mp_mir_", "mp_def_"]

  setup do
    Sandbox.mode(TestRepo, :auto)

    on_exit(fn ->
      for prefix <- @prefixes, kind <- @kinds do
        SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{prefix}#{kind}"), [])
      end

      SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
        [@parity_version, @mirror_version, @default_version]
      ])

      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  describe "the helper against a hand-written mirror" do
    # sabotage: made V01's add_leading_columns/1 skip the leading timestamp
    # pair and add_trailing_timestamps/1 always emit it -> red here, the
    # helper's executions.execution_id row missed the anchor (ordinal 3,
    # not 5). Verified red, reverted.
    # sabotage: made V05's leading-timestamps test `== :never` and its
    # trailing test always true -> red here, the column diff came back
    # non-empty (inputs only). Verified red, reverted.
    # sabotage: made V01's and V05's collated/3 return opts unchanged ->
    # red here, the helper's executions.execution_id row missed the anchor
    # (no "C" collation). Verified red, reverted.
    test "builds the same columns and indexes, table for table" do
      :ok = Migrator.up(TestRepo, @parity_version, MigrateParityHost, log: false)
      :ok = Migrator.up(TestRepo, @mirror_version, MigrateHandMirror, log: false)

      package_columns = columns("mp_pkg_")
      mirror_columns = columns("mp_mir_")

      # Both sides really carry the host's layout, so an empty diff below
      # is a match on it and not two identical defaults.
      assert {"executions", "execution_id", _, _, "C", "NO", 5} =
               List.keyfind(
                 Enum.filter(package_columns, &(elem(&1, 0) == "executions")),
                 "execution_id",
                 1
               )

      assert package_columns |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == @kinds

      assert package_columns -- mirror_columns == []
      assert mirror_columns -- package_columns == []
      assert indexes("mp_pkg_") -- indexes("mp_mir_") == []
      assert indexes("mp_mir_") -- indexes("mp_pkg_") == []
      assert length(indexes("mp_pkg_")) == length(indexes("mp_mir_"))
    end

    # sabotage: made V05.down/1 a no-op -> red here, the rollback left
    # ["mp_pkg_inputs"] behind. Verified red, reverted.
    test "rolls the helper's tables back to none" do
      :ok = Migrator.up(TestRepo, @parity_version, MigrateParityHost, log: false)
      assert tables_like("mp_pkg_") == Enum.map(@kinds, &("mp_pkg_" <> &1))

      :ok = Migrator.down(TestRepo, @parity_version, MigrateParityHost, log: false)
      assert tables_like("mp_pkg_") == []
    end
  end

  describe "the default layout" do
    # sabotage: defaulted :timestamps_position to :leading in Config.new/1
    # -> red here, inserted_at came back at ordinal 2 on all four tables.
    # Verified red, reverted.
    # sabotage: made V01's collated/3 put collation: "C" on every column
    # -> red here, content_hash came back collated. Verified red, reverted.
    test "keeps the timestamp pair last among the created columns, with no collation" do
      :ok = Migrator.up(TestRepo, @default_version, MigrateDefaultLayoutHost, log: false)

      assert names("mp_def_", "charts") ==
               ~w(id content_hash identity_blob chart_blob inserted_at updated_at
                  retired_at retired_by)

      assert names("mp_def_", "positions") ==
               ~w(id session_id content_hash identity_blob position_blob inserted_at
                  updated_at)

      assert names("mp_def_", "executions") ==
               ~w(id execution_id status content_hash identity_blob position_blob failure
                  session_id inserted_at updated_at metadata outcome_blob)

      assert names("mp_def_", "inputs") ==
               ~w(id execution_id seq door input_blob inserted_at updated_at)

      assert for({_, _, _, _, collation, _, _} <- columns("mp_def_"), uniq: true, do: collation) ==
               [nil]
    end
  end

  describe "the options" do
    # sabotage: hardcoded `timestamps_position: :trailing,
    # column_collations: []` in Config.new/1, ignoring both options -> red
    # here on ParityHost's configuration. Verified red, reverted.
    test "default to the package layout and keep what a host configured" do
      assert %Config{timestamps_position: :trailing, column_collations: []} =
               Default.__statifier_persistence__(:config)

      assert %Config{timestamps_position: :leading, column_collations: [execution_id: "C"]} =
               ParityHost.__statifier_persistence__(:config)

      assert %Config{timestamps_position: :leading, column_collations: [door: "C"]} =
               Config.new(
                 repo: TestRepo,
                 timestamps_position: :leading,
                 column_collations: [door: "C"]
               )
    end

    # sabotage: made validate_timestamps_position!/1 return its argument
    # unchecked -> red here, nothing raised for :first. Verified red,
    # reverted.
    test "rejects a timestamps position other than :trailing or :leading" do
      for bad <- [:first, "leading", nil] do
        assert_raise ArgumentError, ~r/:timestamps_position/, fn ->
          Config.new(repo: TestRepo, timestamps_position: bad)
        end
      end
    end

    # sabotage: made validate_column_collations!/1 return its argument
    # unchecked -> red here, nothing raised for the first malformed
    # spelling. Verified red, reverted.
    test "rejects a malformed collation spelling at configuration time" do
      for bad <- [
            :execution_id,
            [{"execution_id", "C"}],
            [execution_id: :C],
            [execution_id: ""],
            [id: "C"],
            [identity_blob: "C"],
            [execution_id: "C", execution_id: "POSIX"]
          ] do
        assert_raise ArgumentError, ~r/:column_collations/, fn ->
          Config.new(repo: TestRepo, column_collations: bad)
        end
      end
    end
  end

  # One row per column of every table under `prefix`, the prefix stripped
  # from the table name: {table, column, data type, udt name, collation,
  # nullability, ordinal position}.
  defp columns(prefix) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT substr(table_name, length($1) + 1), column_name, data_type, udt_name,
               collation_name, is_nullable, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = 'public' AND starts_with(table_name, $1)
        ORDER BY table_name, ordinal_position
        """,
        [prefix]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp names(prefix, kind) do
    for {^kind, name, _, _, _, _, _} <- columns(prefix), do: name
  end

  # One {name, definition} per index on every table under `prefix`, the
  # prefix stripped from both.
  defp indexes(prefix) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT replace(indexname, $1, ''), replace(indexdef, $1, '')
        FROM pg_indexes
        WHERE schemaname = 'public' AND starts_with(tablename, $1)
        ORDER BY indexname
        """,
        [prefix]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp tables_like(prefix) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND starts_with(table_name, $1)
        ORDER BY table_name
        """,
        [prefix]
      )

    List.flatten(rows)
  end
end
