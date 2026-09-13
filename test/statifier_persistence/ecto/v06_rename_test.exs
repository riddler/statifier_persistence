defmodule StatifierPersistence.Ecto.V06RenameTest do
  @moduledoc """
  V06's two install paths on Postgres (ADR-0011 decision 3): the fresh
  database where there is nothing to rename, and the pre-`0.12.0` database
  where the table, both columns and the indexes over them move in place.

  And the three ways down, all of which end with nothing left behind,
  because V06's `down/1` is a no-op (RQ-SF041-25, ruled 2026-09-13): a
  fresh install rolled back in one call, an upgraded install rolled back in
  one call, and a fresh install rolled back one version per host migration
  - the capped pattern this package's own docs recommend, which is the
  shape sp-tae was measured failing on.

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

  # V06 up on the pre-`0.12.0` schema, then the whole rollback in one call.
  defmodule MigrateUpgradedFull do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06u_"]

    def up, do: Migrations.up(@opts ++ [from: 6, version: 6])
    def down, do: Migrations.down(@opts)
  end

  # The capped host pattern, spelled out: one host migration per package
  # version, each capped in both directions, which is what the moduledoc of
  # `StatifierPersistence.Ecto.Migrations` tells a host already running an
  # older version to write. `mix ecto.rollback --all` then rolls back one
  # version per step, and no single `Migrations.down/1` call can see where
  # the rollback ends - the reason V06's `down/1` is a no-op rather than a
  # conditional rename (RQ-SF041-25).
  for version <- 1..6 do
    defmodule Module.concat(__MODULE__, "MigrateCappedV0#{version}") do
      @moduledoc false
      use Ecto.Migration

      alias StatifierPersistence.Ecto.Migrations

      @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06c_"]
      @version version

      def up, do: Migrations.up(@opts ++ [from: @version, version: @version])
      def down, do: Migrations.down(@opts ++ [from: @version, version: @version])
    end
  end

  @fresh_version 20_260_912_000_601
  @upgraded_version 20_260_912_000_602
  @upgraded_full_version 20_260_912_000_603

  # The same pattern over a database that was built before `0.12.0`: its
  # V01-V05 host migrations ran under `0.11.x` and are recorded as such,
  # and V06 is the one it is picking up now.
  for version <- 1..6 do
    defmodule Module.concat(__MODULE__, "MigrateUpgradedCappedV0#{version}") do
      @moduledoc false
      use Ecto.Migration

      alias StatifierPersistence.Ecto.Migrations

      @opts [repo: StatifierPersistence.TestRepo, key: :uxid, table_prefix: "kx_v06x_"]
      @version version

      def up, do: Migrations.up(@opts ++ [from: @version, version: @version])
      def down, do: Migrations.down(@opts ++ [from: @version, version: @version])
    end
  end

  @capped_prefix "kx_v06c_"
  @upgraded_capped_prefix "kx_v06x_"

  # One host migration timestamp per package version, in order.
  @capped_versions Enum.map(1..6, &(20_260_913_000_600 + &1))
  @upgraded_capped_versions Enum.map(1..6, &(20_260_913_000_800 + &1))

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
    # sabotage: gave V06's `down/1` back its rename (restored the body the
    # RQ-SF041-25 ruling removed) -> red here, V03's arm raised
    # `index "kx_v06f_executions_metadata_gin_index" does not exist`
    # because V06 had just renamed it away. Verified red, reverted from a
    # copy.
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

    # V06's `down/1` is a no-op, so `down(for: Host, version: 6)` on an
    # upgraded install leaves the execution names standing rather than
    # restoring the retired ones (RQ-SF041-25). Rolling back below 0.12.0
    # code is unsupported; the way down is the drop below.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here, the
    # executions table was gone and `kx_v06u_runs` was back. Verified red,
    # reverted from a copy.
    test "V06's own down leaves the execution names in place" do
      :ok = migrate(:up, @upgraded_version, MigrateUpgradedV06)
      :ok = migrate(:down, @upgraded_version, MigrateUpgradedV06)

      assert relation_exists?(@upgraded_prefix <> "executions")
      refute relation_exists?(@upgraded_prefix <> "runs")

      assert "execution_id" in columns(@upgraded_prefix <> "executions")
      assert "execution_id" in columns(@upgraded_prefix <> "inputs")
    end

    # Case (b): the whole rollback on an UPGRADED install. V01-V05 drop the
    # tables under the execution names - the names V06 has just given them
    # - and V06's no-op down leaves them alone, so the database is left
    # empty rather than half-renamed.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Postgrex.Error) ERROR 42704 (undefined_object) index
    # "kx_v06u_executions_metadata_gin_index" does not exist` - V03's arm
    # named the index V06 had just renamed away. Verified red, reverted
    # from a copy.
    test "an upgraded install rolls all the way back, leaving nothing behind" do
      :ok = migrate(:up, @upgraded_full_version, MigrateUpgradedFull)

      assert (@upgraded_prefix <> "executions") in tables(@upgraded_prefix)

      :ok = migrate(:down, @upgraded_full_version, MigrateUpgradedFull)

      assert tables(@upgraded_prefix) == []
      refute relation_exists?(@upgraded_prefix <> "runs")
      refute relation_exists?(@upgraded_prefix <> "executions")
    end
  end

  describe "the capped host pattern - one host migration per version" do
    setup do
      drop_capped()
      on_exit(&drop_capped/0)

      :ok
    end

    # Case (c): what sp-tae was filed for. Six host migrations, one per
    # package version, each capped in both directions; `mix ecto.rollback
    # --all` runs their `down`s newest-first, one `Migrations.down/1` call
    # per step. A conditional V06 rename would run in its own step and the
    # V03 and V01 steps behind it would then name objects that are no
    # longer there.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Postgrex.Error) ERROR 42704 (undefined_object) index
    # "kx_v06c_executions_metadata_gin_index" does not exist`: step 6 had
    # renamed the table and its indexes away before the V03 step ran.
    # Verified red, reverted from a copy.
    test "a fresh install migrates up and rolls back --all, one version per step" do
      Enum.each(1..6, fn version ->
        :ok = migrate(:up, capped_version(version), capped_module(version))
      end)

      assert tables(@capped_prefix) == [
               @capped_prefix <> "charts",
               @capped_prefix <> "executions",
               @capped_prefix <> "inputs",
               @capped_prefix <> "positions"
             ]

      assert "execution_id" in columns(@capped_prefix <> "executions")

      # Newest first, which is the order `mix ecto.rollback --all` uses.
      Enum.each(6..1//-1, fn version ->
        :ok = migrate(:down, capped_version(version), capped_module(version))
      end)

      assert tables(@capped_prefix) == []
      refute relation_exists?(@capped_prefix <> "runs")
    end

    # The same six steps over an UPGRADED install: the pre-`0.12.0` schema
    # its V01-V05 host migrations built under `0.11.x` - recorded as run,
    # which is what `schema_migrations` would carry - plus the V06
    # migration it is picking up now. Rolling back --all then runs the V06
    # step first, and V05, V03 and V01 behind it drop what V06 left on the
    # execution names.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Postgrex.Error) ERROR 42704 (undefined_object) index
    # "kx_v06x_executions_metadata_gin_index" does not exist`. Verified
    # red, reverted from a copy.
    test "an upgraded install rolls back --all the same way" do
      create_pre_0_12_schema(@upgraded_capped_prefix)
      record_as_already_run(Enum.take(@upgraded_capped_versions, 5))

      :ok =
        migrate(:up, upgraded_capped_version(6), upgraded_capped_module(6))

      assert (@upgraded_capped_prefix <> "executions") in tables(@upgraded_capped_prefix)
      refute relation_exists?(@upgraded_capped_prefix <> "runs")

      Enum.each(6..1//-1, fn version ->
        :ok = migrate(:down, upgraded_capped_version(version), upgraded_capped_module(version))
      end)

      assert tables(@upgraded_capped_prefix) == []
      refute relation_exists?(@upgraded_capped_prefix <> "runs")
    end
  end

  defp capped_version(version), do: Enum.at(@capped_versions, version - 1)

  defp upgraded_capped_version(version),
    do: Enum.at(@upgraded_capped_versions, version - 1)

  defp upgraded_capped_module(version),
    do: Module.concat(__MODULE__, "MigrateUpgradedCappedV0#{version}")

  # What a host's `schema_migrations` carries for the package migrations it
  # ran under `0.11.x`: the rows, with no DDL behind them beyond the
  # pre-`0.12.0` schema declared by hand above.
  defp record_as_already_run(versions) do
    for version <- versions do
      SQL.query!(
        TestRepo,
        "INSERT INTO schema_migrations (version, inserted_at) VALUES ($1, now())",
        [version]
      )
    end

    :ok
  end

  defp capped_module(version), do: Module.concat(__MODULE__, "MigrateCappedV0#{version}")

  defp drop_capped do
    for prefix <- [@capped_prefix, @upgraded_capped_prefix],
        suffix <- ~w(inputs runs executions positions charts) do
      SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{prefix}#{suffix}"))
    end

    SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = ANY($1)", [
      @capped_versions ++ @upgraded_capped_versions
    ])

    :ok
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
  defp create_pre_0_12_schema, do: create_pre_0_12_schema(@upgraded_prefix)

  defp create_pre_0_12_schema(prefix) do
    SQL.query!(TestRepo, """
    CREATE TABLE "#{prefix}runs" (
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
    CREATE UNIQUE INDEX "#{prefix}runs_run_id_index"
      ON "#{prefix}runs" (run_id)
    """)

    SQL.query!(TestRepo, """
    CREATE INDEX "#{prefix}runs_metadata_gin_index"
      ON "#{prefix}runs" USING GIN (metadata jsonb_path_ops)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{prefix}charts" (
      id text NOT NULL PRIMARY KEY,
      content_hash text NOT NULL,
      identity_blob bytea NOT NULL,
      chart_blob bytea NOT NULL,
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL
    )
    """)

    SQL.query!(TestRepo, """
    CREATE UNIQUE INDEX "#{prefix}charts_content_hash_index"
      ON "#{prefix}charts" (content_hash)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{prefix}positions" (
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
    CREATE UNIQUE INDEX "#{prefix}positions_session_id_index"
      ON "#{prefix}positions" (session_id)
    """)

    SQL.query!(TestRepo, """
    CREATE TABLE "#{prefix}inputs" (
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
    CREATE UNIQUE INDEX "#{prefix}inputs_run_id_seq_index"
      ON "#{prefix}inputs" (run_id, seq)
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
