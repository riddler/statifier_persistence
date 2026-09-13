defmodule StatifierPersistence.Ecto.V06RenameTest do
  @moduledoc """
  V06's two install paths on Postgres (ADR-0011 decision 3): the fresh
  database where there is nothing to rename, and the pre-`0.12.0` database
  where the table, both columns and the indexes over them move in place.

  Live DDL outside the SQL sandbox, like `migrations_test.exs`: `setup_all`
  switches the repo to `:auto` for the module and restores `:manual` on
  exit, hence `async: false`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.TestRepo

  @fresh_prefix "kx_v06f_"
  @upgraded_prefix "kx_v06u_"

  # The whole helper, V01 through V06, on a database that has never held
  # the retired names.
  defmodule MigrateFresh do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06f_"]

    def up, do: Migrations.up(@opts)
    def down, do: Migrations.down(@opts)
  end

  # V06 alone, in both directions, over DDL this module builds by hand in
  # the shape V05 left it at `0.11.x`.
  defmodule MigrateUpgradedV06 do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06u_"]

    def up, do: Migrations.up(@opts ++ [from: 6, version: 6])
    def down, do: Migrations.down(@opts ++ [from: 6, version: 6])
  end

  # V06 up on the pre-`0.12.0` schema, then the whole rollback - the path
  # the RQ-SF041-23 ruling decides (`Migrations.down/1` skips V06's rename
  # when the rollback continues below 6).
  defmodule MigrateUpgradedFull do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06u_"]

    def up, do: Migrations.up(@opts ++ [from: 6, version: 6])
    def down, do: Migrations.down(@opts)
  end

  @fresh_version 20_260_912_000_601
  @upgraded_version 20_260_912_000_602
  @upgraded_full_version 20_260_912_000_603

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)

    :ok
  end

  describe "a fresh install" do
    setup do
      drop_all(@fresh_prefix)
      on_exit(fn -> drop_all(@fresh_prefix) end)

      :ok
    end

    # sabotage: made V06's `up/1` rename unconditionally (dropped the
    # `table_exists?` guard) -> red here, the run raised
    # `relation "kx_v06f_runs" does not exist`. Verified red, reverted from
    # a copy.
    test "V01 through V06 create the execution names directly and V06 renames nothing" do
      :ok = migrate(:up, @fresh_version, MigrateFresh)

      assert tables(@fresh_prefix) == [
               @fresh_prefix <> "charts",
               @fresh_prefix <> "executions",
               @fresh_prefix <> "inputs",
               @fresh_prefix <> "positions"
             ]

      assert "execution_id" in columns(@fresh_prefix <> "executions")
      assert "execution_id" in columns(@fresh_prefix <> "inputs")

      assert unique_index_names(@fresh_prefix <> "executions") == [
               @fresh_prefix <> "executions_execution_id_index"
             ]

      assert unique_index_names(@fresh_prefix <> "inputs") == [
               @fresh_prefix <> "inputs_execution_id_seq_index"
             ]

      assert index_names(@fresh_prefix <> "executions")
             |> Enum.member?(@fresh_prefix <> "executions_metadata_gin_index")

      # The retired names were never created on the way through, which is
      # what makes V06 a no-op here rather than a rename that happened to
      # land on the same place.
      refute relation_exists?(@fresh_prefix <> "runs")
      refute relation_exists?(@fresh_prefix <> "runs_run_id_index")

      assert Migrations.expected_version() == 6
    end

    # The rollback this package advertises - `down(for: Host)`, and
    # `mix ecto.rollback --all` behind it - all the way back from V06 on a
    # database that has never held the retired names.
    #
    # sabotage: made `Migrations.down/1` run V06's `down/1` unconditionally
    # (deleted the `skipped_on_the_way_down?/2` guard) -> red here, V03's
    # arm raised `index "kx_v06f_executions_metadata_gin_index" does not
    # exist` because V06 had just renamed it away. Verified red, reverted
    # from a copy.
    test "V06 through V01 roll the whole DDL back, leaving nothing behind" do
      :ok = migrate(:up, @fresh_version, MigrateFresh)
      :ok = migrate(:down, @fresh_version, MigrateFresh)

      assert tables(@fresh_prefix) == []
      refute relation_exists?(@fresh_prefix <> "runs")
    end
  end

  describe "an upgraded install" do
    setup do
      drop_all(@upgraded_prefix)
      create_pre_0_12_schema()
      seed_pre_0_12_rows()

      on_exit(fn -> drop_all(@upgraded_prefix) end)

      :ok
    end

    # sabotage: dropped V06's `rename_column` call for the input log ->
    # red here, the inputs table still carried `run_id`. A second mutation:
    # dropped the GIN index rename -> red on the index-name assertion.
    # Both verified red, reverted from a copy.
    test "V06 renames the table, both columns and all three indexes in place" do
      :ok = migrate(:up, @upgraded_version, MigrateUpgradedV06)

      assert tables(@upgraded_prefix) == [
               @upgraded_prefix <> "charts",
               @upgraded_prefix <> "executions",
               @upgraded_prefix <> "inputs",
               @upgraded_prefix <> "positions"
             ]

      refute relation_exists?(@upgraded_prefix <> "runs")

      assert "execution_id" in columns(@upgraded_prefix <> "executions")
      refute "run_id" in columns(@upgraded_prefix <> "executions")
      assert "execution_id" in columns(@upgraded_prefix <> "inputs")
      refute "run_id" in columns(@upgraded_prefix <> "inputs")

      assert unique_index_names(@upgraded_prefix <> "executions") == [
               @upgraded_prefix <> "executions_execution_id_index"
             ]

      assert unique_index_names(@upgraded_prefix <> "inputs") == [
               @upgraded_prefix <> "inputs_execution_id_seq_index"
             ]

      assert (@upgraded_prefix <> "executions_metadata_gin_index") in index_names(
               @upgraded_prefix <> "executions"
             )
    end

    # ADR-0011 decision 3 and consent clause 9: no migration in this wave
    # touches the chart or position tables.
    #
    # sabotage: added the charts table to V06's rename list -> red here,
    # the table came back as `kx_v06u_chart_executions`. Verified red,
    # reverted from a copy.
    test "charts and positions are untouched, name, columns and indexes" do
      before_charts =
        {columns(@upgraded_prefix <> "charts"), index_names(@upgraded_prefix <> "charts")}

      before_positions =
        {columns(@upgraded_prefix <> "positions"), index_names(@upgraded_prefix <> "positions")}

      :ok = migrate(:up, @upgraded_version, MigrateUpgradedV06)

      assert {columns(@upgraded_prefix <> "charts"), index_names(@upgraded_prefix <> "charts")} ==
               before_charts

      assert {columns(@upgraded_prefix <> "positions"),
              index_names(@upgraded_prefix <> "positions")} == before_positions
    end

    # sabotage: replaced the rename with a CREATE TABLE AS SELECT copy ->
    # red here, the surrogate ids came back with fresh values. Verified
    # red, reverted from a copy.
    test "the rows read back byte-identical under the new names - no data is copied" do
      before_rows = execution_rows(@upgraded_prefix <> "runs")
      before_inputs = input_rows(@upgraded_prefix <> "inputs")

      :ok = migrate(:up, @upgraded_version, MigrateUpgradedV06)

      assert execution_rows(@upgraded_prefix <> "executions") == before_rows
      assert input_rows(@upgraded_prefix <> "inputs") == before_inputs

      # Every stored id keeps the prefix it was written with: V06 copies no
      # data, so an upgraded install's `run_`-prefixed surrogate keys live
      # on beside the `exec_` ones written afterwards (ADR-0011 decision 2).
      assert [["run_pre012_0"], ["run_pre012_1"]] =
               ids(@upgraded_prefix <> "executions")
    end

    # sabotage: made `down/1` a no-op -> red here, the old names never came
    # back. Verified red, reverted from a copy.
    test "down/1 restores every old name and the same rows" do
      before_rows = execution_rows(@upgraded_prefix <> "runs")
      before_inputs = input_rows(@upgraded_prefix <> "inputs")

      :ok = migrate(:up, @upgraded_version, MigrateUpgradedV06)
      :ok = migrate(:down, @upgraded_version, MigrateUpgradedV06)

      assert relation_exists?(@upgraded_prefix <> "runs")
      refute relation_exists?(@upgraded_prefix <> "executions")

      assert "run_id" in columns(@upgraded_prefix <> "runs")
      assert "run_id" in columns(@upgraded_prefix <> "inputs")

      assert unique_index_names(@upgraded_prefix <> "runs") == [
               @upgraded_prefix <> "runs_run_id_index"
             ]

      assert unique_index_names(@upgraded_prefix <> "inputs") == [
               @upgraded_prefix <> "inputs_run_id_seq_index"
             ]

      assert (@upgraded_prefix <> "runs_metadata_gin_index") in index_names(
               @upgraded_prefix <> "runs"
             )

      assert execution_rows(@upgraded_prefix <> "runs") == before_rows
      assert input_rows(@upgraded_prefix <> "inputs") == before_inputs
    end

    # The other side of the same ruling: when the rollback does not stop at
    # 6, `Migrations.down/1` does not call this `down/1` at all. The tables
    # go under the names V01-V05 declare, and the database is left empty
    # rather than half-renamed.
    #
    # sabotage: deleted the `skipped_on_the_way_down?/2` guard from
    # `Migrations.down/1` -> red here, the run raised on V03's arm and the
    # upgraded tables were still standing under their retired names.
    # Verified red, reverted from a copy.
    test "a rollback that continues below V06 skips the rename and drops everything" do
      :ok = migrate(:up, @upgraded_full_version, MigrateUpgradedFull)

      assert (@upgraded_prefix <> "executions") in tables(@upgraded_prefix)

      :ok = migrate(:down, @upgraded_full_version, MigrateUpgradedFull)

      assert tables(@upgraded_prefix) == []
      refute relation_exists?(@upgraded_prefix <> "runs")
      refute relation_exists?(@upgraded_prefix <> "executions")
    end
  end

  defp migrate(direction, version, module) do
    case apply(Ecto.Migrator, direction, [TestRepo, version, module, [log: false]]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  # The schema V05 left behind at 0.11.x, written out rather than derived:
  # the migrations that built it have been rewritten to the new noun, so
  # the only way to hold the old shape is to declare it.
  defp create_pre_0_12_schema do
    SQL.query!(TestRepo, """
    CREATE TABLE "#{@upgraded_prefix}runs" (
      id text NOT NULL PRIMARY KEY,
      run_id text NOT NULL,
      status text NOT NULL,
      content_hash text NOT NULL,
      identity_blob bytea NOT NULL,
      position_blob bytea,
      failure text,
      session_id text,
      metadata jsonb,
      outcome_blob bytea,
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL
    )
    """)

    SQL.query!(TestRepo, """
    CREATE UNIQUE INDEX "#{@upgraded_prefix}runs_run_id_index"
      ON "#{@upgraded_prefix}runs" (run_id)
    """)

    SQL.query!(TestRepo, """
    CREATE INDEX "#{@upgraded_prefix}runs_metadata_gin_index"
      ON "#{@upgraded_prefix}runs" USING GIN (metadata jsonb_path_ops)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{@upgraded_prefix}charts" (
      id text NOT NULL PRIMARY KEY,
      content_hash text NOT NULL,
      identity_blob bytea NOT NULL,
      chart_blob bytea NOT NULL,
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL
    )
    """)

    SQL.query!(TestRepo, """
    CREATE UNIQUE INDEX "#{@upgraded_prefix}charts_content_hash_index"
      ON "#{@upgraded_prefix}charts" (content_hash)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{@upgraded_prefix}positions" (
      id text NOT NULL PRIMARY KEY,
      session_id text NOT NULL,
      content_hash text NOT NULL,
      identity_blob bytea NOT NULL,
      position_blob bytea NOT NULL,
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL
    )
    """)

    SQL.query!(TestRepo, """
    CREATE UNIQUE INDEX "#{@upgraded_prefix}positions_session_id_index"
      ON "#{@upgraded_prefix}positions" (session_id)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{@upgraded_prefix}inputs" (
      id text NOT NULL PRIMARY KEY,
      run_id text NOT NULL,
      seq bigint NOT NULL,
      door text NOT NULL,
      input_blob bytea,
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL
    )
    """)

    SQL.query!(TestRepo, """
    CREATE UNIQUE INDEX "#{@upgraded_prefix}inputs_run_id_seq_index"
      ON "#{@upgraded_prefix}inputs" (run_id, seq)
    """)

    :ok
  end

  defp seed_pre_0_12_rows do
    for index <- 0..1 do
      SQL.query!(
        TestRepo,
        """
        INSERT INTO "#{@upgraded_prefix}runs"
          (id, run_id, status, content_hash, identity_blob, metadata,
           inserted_at, updated_at)
        VALUES ($1, $2, 'running', 'sha256:pre-0-12', $3, $4, now(), now())
        """,
        ["run_pre012_#{index}", "execution-pre-0-12-#{index}", <<1, 2, 3>>, %{"tenant" => "t1"}]
      )

      SQL.query!(
        TestRepo,
        """
        INSERT INTO "#{@upgraded_prefix}inputs"
          (id, run_id, seq, door, input_blob, inserted_at, updated_at)
        VALUES ($1, $2, 0, 'step', $3, now(), now())
        """,
        ["input_pre012_#{index}", "execution-pre-0-12-#{index}", <<9, 9>>]
      )
    end

    :ok
  end

  defp drop_all(prefix) do
    for suffix <- ~w(inputs runs executions positions charts) do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{prefix}#{suffix}"))
    end

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
      [@fresh_version, @upgraded_version, @upgraded_full_version]
    ])

    :ok
  end

  defp tables(prefix) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name LIKE $1
        ORDER BY table_name
        """,
        [prefix <> "%"]
      )

    List.flatten(rows)
  end

  defp columns(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY column_name
        """,
        [table]
      )

    List.flatten(rows)
  end

  defp index_names(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
        ORDER BY indexname
        """,
        [table]
      )

    List.flatten(rows)
  end

  defp unique_index_names(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
          AND indexdef LIKE 'CREATE UNIQUE INDEX%'
          AND indexname NOT LIKE '%\\_pkey'
        ORDER BY indexname
        """,
        [table]
      )

    List.flatten(rows)
  end

  defp relation_exists?(name) do
    %{rows: [[exists?]]} =
      SQL.query!(TestRepo, "SELECT to_regclass($1) IS NOT NULL", [~s("#{name}")])

    exists?
  end

  defp execution_rows(table) do
    %{rows: rows} =
      SQL.query!(TestRepo, ~s(SELECT * FROM "#{table}" ORDER BY id))

    rows
  end

  defp input_rows(table) do
    %{rows: rows} =
      SQL.query!(TestRepo, ~s(SELECT * FROM "#{table}" ORDER BY id))

    rows
  end

  defp ids(table) do
    %{rows: rows} = SQL.query!(TestRepo, ~s(SELECT id FROM "#{table}" ORDER BY id))

    rows
  end
end
