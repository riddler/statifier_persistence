defmodule StatifierPersistence.Ecto.SqliteMigrationsTest do
  @moduledoc """
  The versioned migration helper, and the Ecto adapter's metadata
  declaration, on an Ecto adapter that is not Postgres (sp-11w).

  0.7.0 could not be adopted by a SQLite host at all: V03's `GIN`
  `jsonb_path_ops` index made `ecto_sqlite3` raise, which rolled the whole
  migration back and took the `outcome_blob` column with it, and capping at
  V02 was equally dead because the generated executions schema reads
  `outcome_blob` unconditionally. These cases are the standing proof that
  V03 runs to completion on such an adapter, that the column arrives and
  the index does not, and that what the index served refuses rather than
  raises. V04's concurrent rebuild of that index (sp-ajz) is a no-op here
  for the same reason, and has a case of its own below.

  ADR-0005 decision 2's Postgres harness is untouched: every storage,
  conformance and lock test still runs against a real Postgres server.
  This module owns its own repo, its own database file, and its own DDL.
  """

  # Its own repo, its own file-backed database, and DDL outside any
  # sandbox: nothing here may run beside another test.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.MachineState
  alias StatifierPersistence.{Driver, Executions, Storage}
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.SqliteTestRepo
  alias StatifierPersistence.SqliteTestRepo.Host

  defmodule MigrateSqlite do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.SqliteTestRepo.Host)
    def down, do: Migrations.down(for: StatifierPersistence.SqliteTestRepo.Host)
  end

  # The README's capped recipe on this adapter, which is where sp-8qq was
  # measured: the first migration stops at V02 in both directions, the
  # second carries V03 alone, and its own tables so nothing above collides.
  defmodule MigrateSqliteCappedV02 do
    @moduledoc false
    use Ecto.Migration

    @opts [
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_cap_"
    ]

    def up, do: Migrations.up(@opts ++ [version: 2])
    def down, do: Migrations.down(@opts ++ [from: 2])
  end

  defmodule MigrateSqliteCappedV03 do
    @moduledoc false
    use Ecto.Migration

    @opts [
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_cap_"
    ]

    def up, do: Migrations.up(@opts ++ [from: 3])
    def down, do: Migrations.down(@opts ++ [version: 3])
  end

  # A pass-through per-execution exclusion. `Storage.Ecto.lock_execution/3` is
  # `pg_advisory_xact_lock` plus `FOR UPDATE` and raises on SQLite, which
  # is sp-5lm's separate Postgres-only surface and not what these cases
  # are about: the fan-out gate below has to be reached to be observed,
  # and reaching it must not depend on a lock this bead does not fix.
  defmodule PassThroughSerialization do
    @moduledoc false

    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(_config, _execution_id, fun), do: {:ok, fun.()}
  end

  # V04's concurrent rebuild (sp-ajz) on this adapter, in the same shape
  # the moduledoc prescribes on Postgres: its own migration, with the DDL
  # transaction and the migration lock disabled. There is no index here
  # for it to rebuild, so the point of the case is that it runs to
  # completion and creates none.
  defmodule MigrateSqliteConcurrentV04 do
    @moduledoc false
    use Ecto.Migration

    @disable_ddl_transaction true
    @disable_migration_lock true

    # Pinned at V04 in both directions: without the ceiling this module
    # drifts forward on every version the package gains, and setup_all
    # has already created V05's table.
    def up, do: Migrations.up(for: StatifierPersistence.SqliteTestRepo.Host, from: 4, version: 4)

    def down,
      do: Migrations.down(for: StatifierPersistence.SqliteTestRepo.Host, from: 4, version: 4)
  end

  @migration_version 20_260_905_000_201

  # V06 alone, in both directions, over DDL the upgraded-install case
  # below builds by hand in the shape V05 left it at 0.11.x.
  defmodule MigrateSqliteV06 do
    @moduledoc false
    use Ecto.Migration

    @opts [
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_up_"
    ]

    def up, do: Migrations.up(@opts ++ [from: 6, version: 6])
    def down, do: Migrations.down(@opts ++ [from: 6, version: 6])
  end

  # A fresh install of its own, migrated up and rolled all the way back in
  # one call - the `down(for: Host)` this package advertises, on a database
  # that has never held the retired names.
  defmodule MigrateSqliteFreshRollback do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_fr_"
    ]

    def up, do: Migrations.up(@opts)
    def down, do: Migrations.down(@opts)
  end

  # V06 up over a hand-declared pre-`0.12.0` schema, then the whole
  # rollback in one call: V01-V05 drop the tables under the execution names
  # V06 has just given them, and V06's own `down/1` does nothing.
  defmodule MigrateSqliteUpgradedFull do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations

    @opts [
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_uf_"
    ]

    # Capped in both directions, which is what this package's moduledoc
    # asks of a capped migration: the up stops at V06, so the down starts
    # there too rather than at whatever the newest version has become.
    def up, do: Migrations.up(@opts ++ [from: 6, version: 6])
    def down, do: Migrations.down(@opts ++ [from: 6])
  end

  # The capped host pattern, spelled out: one host migration per package
  # version, each capped in both directions, which is the shape this
  # package's own moduledoc recommends and the shape sp-tae was measured
  # failing on. `mix ecto.rollback --all` runs their `down`s newest-first,
  # one `Migrations.down/1` call per step, so no single call can see where
  # the rollback ends - the reason V06's `down/1` is a no-op rather than a
  # conditional rename (RQ-SF041-25).
  for version <- 1..6 do
    defmodule Module.concat(__MODULE__, "MigratePerVersionV0#{version}") do
      @moduledoc false
      use Ecto.Migration

      alias StatifierPersistence.Ecto.Migrations

      @opts [
        repo: StatifierPersistence.SqliteTestRepo,
        key: :uxid,
        table_prefix: "sq_c6_"
      ]
      @version version

      def up, do: Migrations.up(@opts ++ [from: @version, version: @version])
      def down, do: Migrations.down(@opts ++ [from: @version, version: @version])
    end
  end

  @concurrent_version 20_260_906_000_401
  @v06_version 20_260_912_000_603
  @fresh_rollback_version 20_260_913_000_701
  @upgraded_full_version 20_260_913_000_702

  # The same pattern over a database that was built before `0.12.0`: its
  # V01-V05 host migrations ran under `0.11.x` and are recorded as such,
  # and V06 is the one it is picking up now.
  for version <- 1..6 do
    defmodule Module.concat(__MODULE__, "MigrateUpgradedPerVersionV0#{version}") do
      @moduledoc false
      use Ecto.Migration

      alias StatifierPersistence.Ecto.Migrations

      @opts [
        repo: StatifierPersistence.SqliteTestRepo,
        key: :uxid,
        table_prefix: "sq_x6_"
      ]
      @version version

      def up, do: Migrations.up(@opts ++ [from: @version, version: @version])
      def down, do: Migrations.down(@opts ++ [from: @version, version: @version])
    end
  end

  # One host migration timestamp per package version, in order.
  @capped_per_version Enum.map(1..6, &(20_260_913_000_710 + &1))
  @upgraded_per_version Enum.map(1..6, &(20_260_913_000_810 + &1))

  @capped_versions [20_260_906_000_301, 20_260_906_000_302]

  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done"/>
  </scxml>
  """

  setup_all do
    database = Keyword.fetch!(SqliteTestRepo.config(), :database)
    File.mkdir_p!(Path.dirname(database))
    remove_database(database)

    {:ok, repo_pid} = SqliteTestRepo.start_link()

    on_exit(fn ->
      stop_repo(repo_pid)
      remove_database(database)
    end)

    :ok = migrate(:up)

    %{database: database}
  end

  describe "the migration helper on a non-Postgres adapter" do
    # sabotage: replaced V03.up/1's postgres?() guard with `true`, so the
    # index is created unconditionally -> red, and red exactly as the bead
    # reports: setup_all raised
    # `** (ArgumentError) using is not supported with SQLite3` and the
    # execution ended "6 tests, 0 failures, 6 invalid" - the rolled-back
    # migration left no tables for any case in this module. Verified red,
    # reverted.
    test "V01 through V07 apply, and the executions table carries every column" do
      assert tables() == ["sq_charts", "sq_executions", "sq_inputs", "sq_positions"]

      columns = columns("sq_executions")

      assert "metadata" in columns
      assert "outcome_blob" in columns
      assert "execution_id" in columns
      assert "status" in columns
    end

    # V08 guards nothing by adapter, so the column and the index arrive
    # here exactly as they do on Postgres.
    #
    # sabotage: removed V08's create(index(...)) and its matching drop/1
    # -> red here, the index list carried no ended_at index. Verified red,
    # reverted from a copy.
    test "V08 adds ended_at and its index on this backend too" do
      assert "ended_at" in columns("sq_executions")
      assert "sq_executions_ended_at_index" in indexes("sq_executions")
    end

    # sabotage: covered by the same execution as the case above - with the guard
    # replaced by `true` this case never executes, because creating the
    # index is what makes setup_all raise. That the index cannot exist
    # here is exactly what it asserts. Verified red (invalid), reverted.
    test "no index on metadata is created" do
      refute Enum.any?(indexes("sq_executions"), &String.contains?(&1, "metadata"))
    end

    # sabotage: dropped V04.up/1's postgres?() guard, so the rebuild ran on
    # this adapter -> red, this case alone ("8 tests, 1 failure"), with
    # `** (ArgumentError) `concurrently` is not supported with SQLite3` out
    # of the drop - the same shape of refusal V03's `using:` once raised.
    # Verified red, reverted.
    test "V04's concurrent rebuild is a no-op here, and needs no attribute of its own" do
      on_exit(fn ->
        SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [
          @concurrent_version
        ])
      end)

      :ok = migrate_capped(:up, @concurrent_version, MigrateSqliteConcurrentV04)

      refute Enum.any?(indexes("sq_executions"), &String.contains?(&1, "metadata"))
      assert "outcome_blob" in columns("sq_executions")

      :ok = migrate_capped(:down, @concurrent_version, MigrateSqliteConcurrentV04)

      refute Enum.any?(indexes("sq_executions"), &String.contains?(&1, "metadata"))
      assert tables() == ["sq_charts", "sq_executions", "sq_inputs", "sq_positions"]
    end

    # The number is backend-independent by construction - it is derived
    # from the migration map and reads no repo - and this case is where
    # that is asserted off Postgres, beside the V01..V05 case above that
    # says this backend really did migrate through it.
    #
    # sabotage: pointed expected_version/0 at @initial_version -> red (left
    # 1, right 5), this case and its Postgres twin alone ("45 tests, 2
    # failures"). Verified red, reverted.
    test "expected_version/0 answers the same version this backend migrated through" do
      assert Migrations.expected_version() == 8
    end

    # sabotage: replaced V03.down/1's postgres?() guard with `true`, so
    # down/1 drops an index that was never created -> red, this case alone
    # ("6 tests, 1 failure") with
    # `** (Exqlite.Error) no such index: sq_executions_metadata_gin_index`.
    # Verified red, reverted.
    test "down/1 rolls the whole DDL back and up/1 puts it back" do
      :ok = migrate(:down)

      assert tables() == []

      :ok = migrate(:up)

      assert tables() == ["sq_charts", "sq_executions", "sq_inputs", "sq_positions"]
    end
  end

  describe "V07 on a non-Postgres adapter" do
    # The index and the two tombstone columns are ordinary DDL on this
    # backend and arrive with everything else.
    #
    # sabotage: removed V07's create(index(...)) and its drop/1 -> red,
    # the index list carried no content_hash entry here, and red on the
    # two Postgres cases beside it ("58 tests, 3 failures" over both
    # migration modules). Verified red, reverted from a copy.
    test "the content_hash index and the two tombstone columns arrive here too" do
      assert Enum.any?(indexes("sq_executions"), &String.contains?(&1, "content_hash"))

      columns = columns("sq_charts")

      assert "retired_at" in columns
      assert "retired_by" in columns
    end

    # The half V07 cannot do here, asserted rather than left implicit:
    # SQLite has no ALTER COLUMN, so the guard skips both modify/3 calls
    # and the blob columns keep the NOT NULL V01 gave them. A retirement
    # is a Postgres capability under this version.
    #
    # sabotage: dropped V07.up/1's postgres?() guard around the two
    # modify/3 calls, so they ran on this adapter -> red, and red the way
    # the guard exists to prevent: setup_all raised
    # `** (ArgumentError) ALTER COLUMN not supported by SQLite3` out of
    # ecto_sqlite3's own column_change/2, the whole migration rolled back
    # and the module ended "24 tests, 0 failures, 24 invalid". Verified
    # red, reverted from a copy.
    test "the chart blob columns keep their NOT NULL here, because this backend has no ALTER COLUMN" do
      not_null = not_null_columns("sq_charts")

      assert "chart_blob" in not_null
      assert "identity_blob" in not_null
    end

    # The consequence of the case above, as the answer a host gets
    # rather than as a fact about the DDL. A retirement here would null
    # two columns the schema still declares NOT NULL, so it refuses at
    # open and names the backend limit; surfacing the constraint
    # violation instead would read as a defect in this package rather
    # than as the capability the store does not have (ADR-0012 decision
    # 6).
    #
    # sabotage: in Storage.Ecto.tombstone_columns_ready?/3, answer
    # `true` unconditionally -> red, and red the way the refusal exists
    # to prevent: the retirement got as far as its UPDATE and the case
    # ended on an Exqlite.Error for a NOT NULL constraint on
    # sq_charts.identity_blob rather than on the refusal. Verified red,
    # reverted from a copy.
    test "a retirement refuses at open here, naming the limit rather than a constraint" do
      {:ok, store} = Storage.new(Storage.Ecto, persistence: Host)
      content_hash = "sha256:sqlite-retire-#{System.unique_integer([:positive])}"

      assert :ok =
               store.adapter.save_chart(store.opts, %{
                 content_hash: content_hash,
                 identity_blob: "identity-bytes",
                 chart_blob: "chart-bytes"
               })

      refute Storage.chart_retirement_supported?(store)

      assert {:error, :chart_retirement_unsupported} =
               Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

      # The drained query is unaffected: what this backend cannot do is
      # carry a tombstone, not count.
      assert {:ok, %{active: 0}} = Executions.executions_on(store, content_hash)
      assert {:ok, chart} = Storage.fetch_chart(store, content_hash)
      assert chart.chart_blob == "chart-bytes"
    end
  end

  describe "V06 on an upgraded install" do
    setup do
      drop_upgraded()
      create_pre_0_12_schema()

      on_exit(&drop_upgraded/0)

      :ok
    end

    # The other half of ADR-0011 decision 3's two install paths, off
    # Postgres: the table, both columns and the two unique indexes move,
    # the GIN index is not there to move, and the rows are the rows.
    #
    # sabotage: dropped V06's non-Postgres index branch, leaving the
    # `ALTER INDEX` arm for every adapter -> red here with
    # `** (Exqlite.Error) near "INDEX": syntax error`. A second mutation:
    # gave V06's `down/1` back its rename -> red on the tail, the tables
    # came back as `sq_up_runs`. Both verified red, reverted from a copy.
    test "renames the table, both columns and both unique indexes, keeping every row" do
      before_rows = rows("sq_up_runs")
      before_inputs = rows("sq_up_inputs")

      :ok = migrate_capped(:up, @v06_version, MigrateSqliteV06)

      assert upgraded_tables() == ["sq_up_executions", "sq_up_inputs"]
      assert "execution_id" in columns("sq_up_executions")
      refute "run_id" in columns("sq_up_executions")
      assert "execution_id" in columns("sq_up_inputs")
      refute "run_id" in columns("sq_up_inputs")

      assert "sq_up_executions_execution_id_index" in indexes("sq_up_executions")
      assert "sq_up_inputs_execution_id_seq_index" in indexes("sq_up_inputs")
      refute Enum.any?(indexes("sq_up_executions"), &String.contains?(&1, "metadata"))

      assert rows("sq_up_executions") == before_rows
      assert rows("sq_up_inputs") == before_inputs

      # V06's `down/1` is a no-op (RQ-SF041-25), so rolling this migration
      # back leaves the execution names standing: a downgrade to
      # pre-`0.12.0` code is unsupported, and the way down is the drop the
      # cases below exercise, not a rename.
      :ok = migrate_capped(:down, @v06_version, MigrateSqliteV06)

      assert upgraded_tables() == ["sq_up_executions", "sq_up_inputs"]
      assert "execution_id" in columns("sq_up_executions")
      assert "sq_up_executions_execution_id_index" in indexes("sq_up_executions")
      assert "sq_up_inputs_execution_id_seq_index" in indexes("sq_up_inputs")
      assert rows("sq_up_executions") == before_rows
      assert rows("sq_up_inputs") == before_inputs
    end

    # sabotage: made V06's `up/1` rename unconditionally -> red here with
    # `no such table: sq_up_runs`. Verified red, reverted from a copy.
    test "a fresh install on this adapter has nothing for V06 to rename" do
      # The suite-wide `sq_` tables above were built by V01-V06 in
      # `setup_all`, on an empty database: the retired names never existed.
      refute "sq_runs" in tables()
      assert "execution_id" in columns("sq_executions")
      assert "sq_executions_execution_id_index" in indexes("sq_executions")
    end
  end

  describe "rolling all the way back on this adapter" do
    setup do
      drop_prefixed("sq_fr_", @fresh_rollback_version)
      drop_prefixed("sq_uf_", @upgraded_full_version)

      on_exit(fn ->
        drop_prefixed("sq_fr_", @fresh_rollback_version)
        drop_prefixed("sq_uf_", @upgraded_full_version)
      end)

      :ok
    end

    # Case (a): a fresh install, one call each way.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Exqlite.Error) no such table: sq_fr_executions` - V06 renamed
    # the table away and the arms behind it named what was no longer
    # there. Verified red, reverted from a copy.
    test "a fresh install rolls back to nothing" do
      :ok = migrate_capped(:up, @fresh_rollback_version, MigrateSqliteFreshRollback)

      assert prefixed_tables("sq_fr_") ==
               ["sq_fr_charts", "sq_fr_executions", "sq_fr_inputs", "sq_fr_positions"]

      :ok = migrate_capped(:down, @fresh_rollback_version, MigrateSqliteFreshRollback)

      assert prefixed_tables("sq_fr_") == []
    end

    # Case (b): an upgraded install - the hand-declared pre-`0.12.0` schema
    # plus V06 up - rolls back to nothing too, because V01-V05 drop the
    # tables under the names V06 left them on.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Exqlite.Error) no such table: sq_uf_executions`. Verified red,
    # reverted from a copy.
    test "an upgraded install rolls back to nothing" do
      create_pre_0_12_schema("sq_uf_", :with_chart_and_position_tables)

      :ok = migrate_capped(:up, @upgraded_full_version, MigrateSqliteUpgradedFull)

      assert "sq_uf_executions" in prefixed_tables("sq_uf_")
      refute "sq_uf_runs" in prefixed_tables("sq_uf_")

      :ok = migrate_capped(:down, @upgraded_full_version, MigrateSqliteUpgradedFull)

      assert prefixed_tables("sq_uf_") == []
    end
  end

  describe "the capped host pattern - one host migration per version" do
    setup do
      drop_capped_per_version()
      on_exit(&drop_capped_per_version/0)

      :ok
    end

    # Case (c): what sp-tae was filed for, on the backend it was measured
    # on. Six host migrations, one per package version; the rollback runs
    # their `down`s newest-first, one `Migrations.down/1` call per step.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Exqlite.Error) no such table: sq_c6_executions` - step 6 had
    # renamed the table to `sq_c6_runs` before the steps behind it ran,
    # which is the failure the bead reports. Verified red, reverted from a
    # copy.
    test "a fresh install migrates up and rolls back --all, one version per step" do
      Enum.each(1..6, fn version ->
        :ok = migrate_capped(:up, capped_per_version(version), capped_per_version_module(version))
      end)

      assert prefixed_tables("sq_c6_") ==
               ["sq_c6_charts", "sq_c6_executions", "sq_c6_inputs", "sq_c6_positions"]

      assert "execution_id" in columns("sq_c6_executions")

      # Newest first, which is the order `mix ecto.rollback --all` uses.
      Enum.each(6..1//-1, fn version ->
        :ok =
          migrate_capped(:down, capped_per_version(version), capped_per_version_module(version))
      end)

      assert prefixed_tables("sq_c6_") == []
      refute "sq_c6_runs" in tables()
    end

    # The same six steps over an UPGRADED install on this adapter: the
    # pre-`0.12.0` schema its V01-V05 host migrations built under `0.11.x`,
    # recorded as run, plus the V06 migration it is picking up now.
    #
    # sabotage: gave V06's `down/1` back its rename -> red here,
    # `** (Exqlite.Error) no such table: sq_x6_executions`. Verified red,
    # reverted from a copy.
    test "an upgraded install rolls back --all the same way" do
      create_pre_0_12_schema("sq_x6_", :with_chart_and_position_tables)
      record_as_already_run(Enum.take(@upgraded_per_version, 5))

      :ok = migrate_capped(:up, upgraded_per_version(6), upgraded_per_version_module(6))

      assert "sq_x6_executions" in prefixed_tables("sq_x6_")
      refute "sq_x6_runs" in prefixed_tables("sq_x6_")

      Enum.each(6..1//-1, fn version ->
        :ok =
          migrate_capped(
            :down,
            upgraded_per_version(version),
            upgraded_per_version_module(version)
          )
      end)

      assert prefixed_tables("sq_x6_") == []
    end
  end

  describe "the capped recipe from the README" do
    # sabotage: dropped down/1's `from:` ceiling (back to the unconditional
    # @current_version start) -> red exactly as the bead reports: the second
    # rollback re-ran V03.down and failed with
    # `** (Exqlite.Error) no such column: "outcome_blob"`. Verified red,
    # reverted.
    test "a V01-V02 migration and a V03 migration roll all the way back" do
      [capped_version, v03_version] = @capped_versions

      on_exit(fn ->
        SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_cap_inputs", [])
        SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_cap_executions", [])
        SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_cap_positions", [])
        SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_cap_charts", [])

        SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [
          capped_version
        ])

        SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [
          v03_version
        ])
      end)

      :ok = migrate_capped(:up, capped_version, MigrateSqliteCappedV02)
      :ok = migrate_capped(:up, v03_version, MigrateSqliteCappedV03)

      assert capped_tables() ==
               ["sq_cap_charts", "sq_cap_executions", "sq_cap_inputs", "sq_cap_positions"]

      assert "outcome_blob" in columns("sq_cap_executions")

      # Newest first, which is the order `mix ecto.rollback --all` uses.
      :ok = migrate_capped(:down, v03_version, MigrateSqliteCappedV03)
      :ok = migrate_capped(:down, capped_version, MigrateSqliteCappedV02)

      assert capped_tables() == []
    end
  end

  describe "what the skipped index served" do
    # sabotage: made Storage.Ecto.supports_metadata?/1 return `true`
    # unconditionally again -> red here on the first assertion ("Expected
    # false or nil, got true" for `metadata_supported?/1`), and red in the
    # fan-out case below, which started the child instead of refusing.
    # Verified red, reverted.
    test "the store declares no metadata support, and the listings refuse" do
      store = sqlite_store()

      refute Storage.metadata_supported?(store)
      refute Storage.child_listing_supported?(store)
      refute Storage.execution_states_supported?(store)

      match = Linkage.invocation_match("execution_sqlite_absent", "call")

      assert {:error, :child_listing_unsupported} =
               Storage.list_executions_by_metadata(store, match)

      assert {:error, :execution_states_unsupported} =
               Storage.list_execution_states_by_metadata(store, match)
    end

    # sabotage: dropped the metadata_supported?/1 conjunct from
    # Storage.child_listing_supported?/1 alone -> red, and instructively:
    # the fan-out got past the listing arm and refused
    # `:execution_states_unsupported` from the next one instead, which is the
    # projection's own conjunct holding. Verified red, reverted.
    test "a fan-out over this store is refused at open, not started" do
      store = sqlite_store()
      driver = start_parent(store, "execution_sqlite_fanout")

      assert {:refused, :child_listing_unsupported} =
               Driver.start_child_at(driver, "execution_sqlite_fanout", effect(), 0, 2)

      assert {:error, :execution_not_found} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_sqlite_fanout", "call", 0)
               )
    end

    # sabotage: dropped the supports_metadata?/1 conjunct from both raw
    # listings in Storage.Ecto, so each issues its containment SQL again ->
    # red, this case alone ("14 tests, 1 failure") with
    # `** (Exqlite.Error) unrecognized token: "@"` out of
    # list_executions_by_metadata/2 - the raise this bead replaces. Verified red,
    # reverted.
    test "the raw listings refuse too, rather than raising on SQL this backend cannot parse" do
      store = sqlite_store()
      match = Linkage.invocation_match("execution_sqlite_absent", "call")

      assert {:error, :metadata_unsupported} =
               Storage.Ecto.list_executions_by_metadata(store.opts, match)

      assert {:error, :metadata_unsupported} =
               Storage.Ecto.list_execution_states_by_metadata(store.opts, match)
    end

    # sabotage: made Storage.Ecto.supports_execution_outcome?/1 answer the same
    # adapter check supports_metadata?/1 does -> red ("Expected truthy,
    # got false"). The column exists on every adapter, and declaring
    # otherwise contradicts the migration case above. Verified red,
    # reverted.
    test "execution outcome support is still declared: outcome_blob exists here" do
      assert Storage.execution_outcome_supported?(sqlite_store())
    end
  end

  # sp-y7n / RQ-SF035-9, the SQLite half of the pair whose Postgres half is
  # `StatifierPersistence.DriverSubchartEctoTest`. It asserts something
  # different from that half, because this backend can hold no linkage at
  # all: ADR-0008 decision 2 puts a child's parent in execution `metadata`, and
  # `Storage.Ecto` declares metadata support only on Postgres, so the
  # refusal that stops a fan-out at open stops a single durable subchart
  # child at open too. What `driver:` therefore has to be here is inert -
  # an outside fail behaves exactly as it did before the option existed.
  describe "an outside fail on this adapter" do
    # `serialization:` is the host's here for the same reason the rest of
    # this module's driving is: `AdapterLock` issues
    # `pg_advisory_xact_lock`, which this backend has no function for.
    #
    # sabotage: replaced `Driver.resolve_and_answer_parent/3`'s whole
    # `case` with a bare `{:ok, linkage} = parent_link(...)` match -> red,
    # this case and its in-memory sibling in `DriverSubchartTest`, with
    # `** (MatchError) no match of right hand side value: :no_parent`. The
    # read reaches `:no_parent` rather than the metadata refusal: the row
    # is fetched fine, it simply carries no metadata on this backend.
    # Verified red, reverted.
    test "no linkage can be stored here, so a fail with driver: answers nobody" do
      store = sqlite_store()
      driver = start_parent(store, "execution_sqlite_fail_parent")

      {:ok, machine} = Statifier.compile(@child_source)
      machine_state = MachineState.new(machine, session_id: "sess_sqlite_fail")

      linkage = Linkage.new("execution_sqlite_fail_parent", "call", 0, "sha256:whatever")

      assert {:error, :metadata_unsupported} =
               Storage.insert_execution(
                 store,
                 "execution_sqlite_fail_child",
                 machine_state,
                 :active,
                 metadata: Linkage.to_metadata(linkage)
               )

      :ok = Storage.insert_execution(store, "execution_sqlite_fail_child", machine_state, :active)

      assert {:ok, execution} =
               Executions.fail(store, "execution_sqlite_fail_child", "boom",
                 driver: driver,
                 serialization: {PassThroughSerialization, nil}
               )

      assert execution.status == :failed
      assert execution.failure == "boom"

      assert {:ok, parent_record} = Storage.fetch_execution(store, "execution_sqlite_fail_parent")
      assert parent_record.status == :active
    end
  end

  describe "V05's input log on this adapter" do
    # These mirror, case for case, the input-log cases
    # `StatifierPersistence.Testing.StorageConformance` generates and the
    # Ecto adapter passes against Postgres. They are written out here
    # rather than generated because this module owns its own repo, its own
    # file-backed database and no sandbox, so the case template's per-test
    # `init/1` and `isolate/1` setup does not apply. ADR-0010 decision 9
    # makes SQLite no lesser tier: nothing in the design needs a
    # Postgres-only feature, and this is where that is checked.

    # sabotage: made Storage.Ecto.append_input/3 take its ordinal from a
    # constant 0 rather than next_slot/2 -> red here on the second append,
    # which came back {:adapter, :seq_conflict} off the V05 unique index -
    # SQLite enforcing exactly what Postgres does, and red on the Postgres
    # conformance cases in the same execution. Verified red, reverted.
    test "append_input/3 assigns dense ordinals from zero and lists them in order" do
      store = sqlite_store()
      execution_id = logged_execution(store, "execution_sqlite_log_order")

      for {door, index} <- Enum.with_index(["step", "done_invocation", "answer_parent"]) do
        assert {:ok, ^index} =
                 Storage.Ecto.append_input(store.opts, execution_id, %{
                   execution_id: execution_id,
                   seq: 0,
                   door: door,
                   input_blob: <<index>>
                 })
      end

      assert {:ok, entries} = Storage.Ecto.list_inputs(store.opts, execution_id)

      assert Enum.map(entries, &{&1.seq, &1.door, &1.input_blob}) == [
               {0, "step", <<0>>},
               {1, "done_invocation", <<1>>},
               {2, "answer_parent", <<2>>}
             ]
    end

    # sabotage: dropped Storage.Ecto.list_inputs/2's execution_exists?/2 check ->
    # red, this case got {:ok, []} where it asserted :execution_not_found.
    # Verified red, reverted.
    test "list_inputs/2 reports :execution_not_found for an unknown execution_id" do
      store = sqlite_store()

      assert {:error, :execution_not_found} =
               Storage.Ecto.list_inputs(store.opts, "execution_sqlite_log_absent")
    end

    # sabotage: dropped the execution_id filter from Storage.Ecto.input_rows/2 ->
    # red, the second execution's log came back carrying the first execution's entries.
    # Verified red, reverted.
    test "two executions' logs never see each other's entries" do
      store = sqlite_store()
      mine = logged_execution(store, "execution_sqlite_log_mine")
      theirs = logged_execution(store, "execution_sqlite_log_theirs")

      assert {:ok, 0} = Storage.append_input(store, mine, :step, event("go"))
      assert {:ok, 1} = Storage.append_input(store, mine, :step, event("go"))

      assert {:ok, 0} =
               Storage.append_input(store, theirs, :answer_parent, event("done.invoke.call"))

      assert {:ok, ours} = Storage.list_inputs(store, mine)
      assert {:ok, others} = Storage.list_inputs(store, theirs)

      assert Enum.map(ours, & &1.seq) == [0, 1]
      assert Enum.map(others, &{&1.seq, &1.door}) == [{0, "answer_parent"}]
    end

    # sabotage: returned {:error, :input_log_full} from the `:marker` arm
    # of Storage.Ecto.append_input/3 without inserting the marker row ->
    # red, the log came back two entries long and its last entry was a
    # real input rather than the nil-blob marker. Verified red, reverted.
    test "a cap of n admits n - 1 inputs, then closes the log with a marker" do
      {:ok, capped} = Storage.new(Storage.Ecto, persistence: Host, input_log_cap: 3)
      execution_id = logged_execution(capped, "execution_sqlite_log_cap")

      assert {:ok, 0} = Storage.append_input(capped, execution_id, :step, event("go"))
      assert {:ok, 1} = Storage.append_input(capped, execution_id, :step, event("go"))

      assert {:error, :input_log_full} =
               Storage.append_input(capped, execution_id, :step, event("go"))

      assert {:error, :input_log_full} =
               Storage.append_input(capped, execution_id, :step, event("go"))

      assert {:ok, entries} = Storage.list_inputs(capped, execution_id)
      assert Enum.map(entries, & &1.seq) == [0, 1, 2]
      assert Enum.map(entries, & &1.event) |> List.last() == nil

      # The refusal is the log's, never the execution's.
      assert {:ok, %{status: :active}} = Storage.fetch_execution(capped, execution_id)
    end

    # sabotage: encoded only the event's name in Storage.append_input/4 ->
    # red, the decoded entry was a binary rather than the equal
    # %Statifier.Event{}, caller_context and all. Verified red, reverted.
    test "an event round-trips through the log equal to what was delivered" do
      store = sqlite_store()
      execution_id = logged_execution(store, "execution_sqlite_log_roundtrip")

      delivered = %Event{
        name: "done.invoke.call",
        type: :internal,
        data: %{"email" => "buyer@example.com"},
        invokeid: "call",
        caller_context: %{"tenant" => "acme"}
      }

      assert Storage.input_log_supported?(store)
      assert {:ok, 0} = Storage.append_input(store, execution_id, :done_invocation, delivered)

      assert {:ok, [entry]} = Storage.list_inputs(store, execution_id)
      assert entry.door == "done_invocation"
      assert entry.event == delivered
    end
  end

  defp event(name), do: %Event{name: name, type: :external}

  defp logged_execution(store, execution_id) do
    {:ok, machine} = Statifier.compile(@child_source)
    machine_state = MachineState.new(machine, session_id: "sess_" <> execution_id)

    :ok = Storage.insert_execution(store, execution_id, machine_state, :active)

    execution_id
  end

  defp sqlite_store do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Host)
    store
  end

  defp start_parent(store, execution_id) do
    {:ok, machine} = Statifier.compile(@parent_source)

    driver =
      Driver.new(store, machine,
        dispatch: fn "myapp:map", _params, _context -> :pending end,
        invoke_types: InvokeTypes.new(types: ["myapp:map"]),
        serialization: {PassThroughSerialization, nil}
      )

    {:ok, _execution, _machine_state} = Driver.create(driver, execution_id)
    driver
  end

  defp effect do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: %{},
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end

  defp migrate(direction) do
    case apply(Migrator, direction, [
           SqliteTestRepo,
           @migration_version,
           MigrateSqlite,
           [log: false]
         ]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  defp migrate_capped(direction, version, module) do
    case apply(Migrator, direction, [SqliteTestRepo, version, module, [log: false]]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  defp capped_tables do
    Enum.filter(tables(), &String.starts_with?(&1, "sq_cap_"))
  end

  defp upgraded_tables do
    %{rows: rows} =
      SQL.query!(
        SqliteTestRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sq_up_%' " <>
          "ORDER BY name",
        []
      )

    List.flatten(rows)
  end

  defp rows(table) do
    %{rows: rows} = SQL.query!(SqliteTestRepo, "SELECT * FROM #{table} ORDER BY id", [])
    rows
  end

  defp drop_upgraded do
    for suffix <- ~w(inputs runs executions) do
      SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_up_#{suffix}", [])
    end

    SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [
      @v06_version
    ])

    :ok
  end

  # The shape V05 left behind at 0.11.x. The migrations that built it have
  # been rewritten to the new noun, so the only way to hold the old shape
  # is to declare it.
  #
  # The durable pair is all the rename cases need; a case that rolls the
  # whole DDL back needs the chart and position tables too, because V01's
  # `down/1` drops all three.
  defp create_pre_0_12_schema, do: create_pre_0_12_schema("sq_up_", :durable_tables_only)

  defp create_pre_0_12_schema(prefix, extras) do
    SQL.query!(SqliteTestRepo, """
    CREATE TABLE #{prefix}runs (
      id TEXT NOT NULL PRIMARY KEY,
      run_id TEXT NOT NULL,
      status TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      identity_blob BLOB NOT NULL,
      position_blob BLOB,
      failure TEXT,
      session_id TEXT,
      metadata TEXT,
      outcome_blob BLOB,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    SQL.query!(
      SqliteTestRepo,
      "CREATE UNIQUE INDEX #{prefix}runs_run_id_index ON #{prefix}runs (run_id)",
      []
    )

    SQL.query!(SqliteTestRepo, """
    CREATE TABLE #{prefix}inputs (
      id TEXT NOT NULL PRIMARY KEY,
      run_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      door TEXT NOT NULL,
      input_blob BLOB,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    SQL.query!(
      SqliteTestRepo,
      "CREATE UNIQUE INDEX #{prefix}inputs_run_id_seq_index ON #{prefix}inputs (run_id, seq)",
      []
    )

    SQL.query!(SqliteTestRepo, """
    INSERT INTO #{prefix}runs
      (id, run_id, status, content_hash, identity_blob, inserted_at, updated_at)
    VALUES ('run_pre012_0', 'execution-pre-0-12-0', 'running', 'sha256:pre-0-12',
            x'010203', '2026-09-12 00:00:00', '2026-09-12 00:00:00')
    """)

    SQL.query!(SqliteTestRepo, """
    INSERT INTO #{prefix}inputs
      (id, run_id, seq, door, input_blob, inserted_at, updated_at)
    VALUES ('input_pre012_0', 'execution-pre-0-12-0', 0, 'step', x'0909',
            '2026-09-12 00:00:00', '2026-09-12 00:00:00')
    """)

    if extras == :with_chart_and_position_tables do
      SQL.query!(SqliteTestRepo, """
      CREATE TABLE #{prefix}charts (
        id TEXT NOT NULL PRIMARY KEY,
        content_hash TEXT NOT NULL,
        identity_blob BLOB NOT NULL,
        chart_blob BLOB NOT NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """)

      SQL.query!(SqliteTestRepo, """
      CREATE TABLE #{prefix}positions (
        id TEXT NOT NULL PRIMARY KEY,
        session_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        identity_blob BLOB NOT NULL,
        position_blob BLOB NOT NULL,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """)
    end

    :ok
  end

  defp prefixed_tables(prefix) do
    Enum.filter(tables(), &String.starts_with?(&1, prefix))
  end

  defp drop_prefixed(prefix, version) do
    for suffix <- ~w(inputs runs executions positions charts) do
      SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS #{prefix}#{suffix}", [])
    end

    SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [version])

    :ok
  end

  defp capped_per_version(version), do: Enum.at(@capped_per_version, version - 1)

  defp upgraded_per_version(version), do: Enum.at(@upgraded_per_version, version - 1)

  defp upgraded_per_version_module(version),
    do: Module.concat(__MODULE__, "MigrateUpgradedPerVersionV0#{version}")

  # What a host's `schema_migrations` carries for the package migrations it
  # ran under `0.11.x`: the rows, with no DDL behind them beyond the
  # pre-`0.12.0` schema declared by hand above.
  defp record_as_already_run(versions) do
    for version <- versions do
      SQL.query!(
        SqliteTestRepo,
        "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, datetime('now'))",
        [version]
      )
    end

    :ok
  end

  defp capped_per_version_module(version),
    do: Module.concat(__MODULE__, "MigratePerVersionV0#{version}")

  defp drop_capped_per_version do
    for prefix <- ["sq_c6_", "sq_x6_"],
        suffix <- ~w(inputs runs executions positions charts) do
      SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS #{prefix}#{suffix}", [])
    end

    for version <- @capped_per_version ++ @upgraded_per_version do
      SQL.query!(SqliteTestRepo, "DELETE FROM schema_migrations WHERE version = ?1", [version])
    end

    :ok
  end

  defp tables do
    %{rows: rows} =
      SQL.query!(
        SqliteTestRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sq_%' ORDER BY name",
        []
      )

    List.flatten(rows)
  end

  # PRAGMA table_info's fourth column is notnull, 1 for a NOT NULL column.
  defp not_null_columns(table) do
    %{rows: rows} = SQL.query!(SqliteTestRepo, "PRAGMA table_info(#{table})", [])

    rows
    |> Enum.filter(fn row -> Enum.at(row, 3) == 1 end)
    |> Enum.map(fn row -> Enum.at(row, 1) end)
  end

  defp columns(table) do
    %{rows: rows} = SQL.query!(SqliteTestRepo, "PRAGMA table_info(#{table})", [])
    Enum.map(rows, fn row -> Enum.at(row, 1) end)
  end

  defp indexes(table) do
    %{rows: rows} = SQL.query!(SqliteTestRepo, "PRAGMA index_list(#{table})", [])
    Enum.map(rows, fn row -> Enum.at(row, 1) end)
  end

  # `Supervisor.stop/1` on a repo that is already on its way down exits
  # with `:normal`, which ExUnit reports as an on_exit failure and
  # invalidates the whole module. The file removal below is the part that
  # matters.
  defp stop_repo(repo_pid) do
    if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # SQLite keeps a write-ahead log and a shared-memory file beside the
  # database; leaving either behind would carry state into the next execution.
  defp remove_database(database) do
    for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    :ok
  end
end
