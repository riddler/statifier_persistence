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

  It also drives durable subchart children on this backend, for the host
  that sets `linkage_columns: true` and the one that does not (ADR-0008's
  2026-11-19 Amendment, point 8), under `PassThroughSerialization`.
  """

  # Its own repo, its own file-backed database, and DDL outside any
  # sandbox: nothing here may run beside another test.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias Statifier.MachineState
  alias StatifierPersistence.{Driver, Executions, Storage}
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.SqliteTestRepo
  alias StatifierPersistence.SqliteTestRepo.{Host, LinkedHost}
  alias StatifierPersistence.Test.LoopingSubchart

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
  # conditional rename (ruled by the operator, 2026-09-13).
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

  # The parent above with a way out of the invoking state, so leaving it
  # fires the `{:cancel_invoke, _}` effect.
  @cancelling_parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="approved"/>
      <state id="abandoned"/>
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
      assert Migrations.expected_version() == 9
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

      # V06's `down/1` is a no-op (ruled by the operator, 2026-09-13), so
      # rolling this migration back leaves the execution names standing: a downgrade to
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
    # Verified red, reverted. And answered `{:ok, []}` from
    # Executions.active_children/2 when the listing refused -> red on its
    # assertion here. Verified red, reverted from a copy.
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

      assert {:error, :child_listing_unsupported} =
               Executions.active_children(store, "execution_sqlite_absent")
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

  # sp-y7n (ruled by the operator, 2026-09-06), the SQLite half of the
  # pair whose Postgres half is `StatifierPersistence.DriverSubchartEctoTest`.
  # It asserts something
  # different from that half, because this backend can hold no linkage at
  # all: ADR-0008 decision 2 puts a child's parent in execution `metadata`, and
  # `Storage.Ecto` declares metadata support only on Postgres, so the
  # refusal that stops a fan-out at open stops a single durable subchart
  # child at open too. What `driver:` therefore has to be here is inert -
  # an outside fail behaves exactly as it did before the option existed.
  #
  # That is the host that leaves `linkage_columns:` off. ADR-0008's
  # 2026-11-19 Amendment gives the host that sets it a home for the
  # linkage, and the second case below is that host: its outside fail
  # answers the parent, as on Postgres.
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

    # ADR-0008's 2026-11-19 Amendment, point 8: the same outside fail, for
    # the host that opts in, now answers the parent.
    #
    # sabotage: in Executions.answer_parent_of_failed/4, dropped the
    # driver clause's Driver.resolve_and_answer_parent/3 call -> red, the
    # parent stayed in "calling". Verified red, reverted from a copy.
    test "with the linkage columns option on, a fail with driver: answers the parent" do
      store = linked_store()
      parent = "execution_loan_fail_parent"

      driver =
        linked_driver(store, @parent_source, subchart_dispatch(),
          chart_resolver: parent_resolver()
        )

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      child = Linkage.child_execution_id(parent, "call", 0)

      assert {:ok, %{status: :failed, failure: "boom"}} =
               Executions.fail(store, child, "boom",
                 driver: driver,
                 serialization: {PassThroughSerialization, nil}
               )

      parent_state = reload(store, @parent_source, parent)
      assert leaves(parent_state) == ["refused"]
      assert parent_state.datamodel["_event"]["data"]["reason"] == "boom"
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

  describe "pruning finished executions on this adapter" do
    # Mirrors the conformance suite's input log prune case, which the Ecto
    # adapter passes against Postgres: the selection's EXISTS over the
    # inputs table, and the absence of a row lock, are what this backend
    # has to parse (ADR-0016).
    #
    # sabotage: gave Storage.Ecto's due_executions/4 its Postgres row
    # lock on every backend -> red here, the batch raised on a lock
    # clause SQLite does not have. Verified red, reverted from a copy.
    test "Retention.prune/3 clears a finished execution's position and log and keeps its row" do
      store = sqlite_store()
      {:ok, machine} = Statifier.compile(@child_source)
      finished = "execution_sqlite_prune_finished"
      machine_state = MachineState.new(machine, session_id: "sess_" <> finished)

      :ok =
        Storage.insert_execution(
          store,
          finished,
          machine_state,
          :completed,
          [],
          ~U[2026-01-01 00:00:00.000000Z]
        )

      running = logged_execution(store, "execution_sqlite_prune_running")

      assert {:ok, 0} = Storage.append_input(store, finished, :step, event("go"))
      assert {:ok, 1} = Storage.append_input(store, finished, :step, event("go"))
      assert {:ok, 0} = Storage.append_input(store, running, :step, event("go"))

      assert {:ok, %{executions: 1, position_blobs: 1, inputs: 2}} =
               StatifierPersistence.Retention.prune(store, ~U[2026-02-01 00:00:00.000000Z])

      assert {:ok, %{status: :completed, position_blob: nil, ended_at: %DateTime{}}} =
               Storage.fetch_execution(store, finished)

      assert {:ok, []} = Storage.list_inputs(store, finished)
      assert {:ok, [%{seq: 0}]} = Storage.list_inputs(store, running)
    end
  end

  # ADR-0008's 2026-11-19 Amendment, the storage half, on this adapter.
  # `Host` leaves `linkage_columns:` at its default and `LinkedHost` sets
  # it, over the same `sq_` tables: the first block is the host that
  # changes nothing, the second the host that opts in.
  describe "the linkage columns option left off on this adapter" do
    # sabotage: made Storage.Ecto's linkage_columns?/1 ignore the option -> red here
    # on `refute supports_linkage?`; and passed the default arm's insert its
    # metadata minus the reserved key -> red here on `assert is_binary(stored)`.
    # Each verified red, reverted from a copy.
    test "a host that changes nothing stores and answers a linkage as before" do
      store = sqlite_store()
      opts = store.opts
      linkage = Linkage.new("execution_loan_off", "renewals", 0, "sha256:loan-off-child")
      child = Linkage.child_execution_id("execution_loan_off", "renewals", 0)

      refute Storage.Ecto.supports_linkage?(opts)
      refute Storage.linkage_supported?(store)
      refute Enum.any?(Host.Execution.__schema__(:fields), &linkage_field?/1)

      :ok =
        Storage.Ecto.insert_execution(
          opts,
          raw_record(child, %{metadata: Linkage.to_metadata(linkage)})
        )

      assert %{rows: [[stored, nil, nil]]} =
               SQL.query!(
                 SqliteTestRepo,
                 "SELECT metadata, linkage_parent_execution_id, linkage_content_hash " <>
                   "FROM sq_executions WHERE execution_id = ?1",
                 [child]
               )

      assert is_binary(stored)
      assert JSON.decode!(stored) == Linkage.to_metadata(linkage)

      assert {:ok, %{metadata: metadata}} = Storage.Ecto.fetch_execution(opts, child)
      assert metadata == Linkage.to_metadata(linkage)

      assert {:error, :metadata_unsupported} =
               Storage.Ecto.list_executions_by_metadata(
                 opts,
                 Linkage.parent_match("execution_loan_off")
               )

      assert {:ok, %{children: 0}} =
               Storage.Ecto.count_executions_by_content_hash(opts, "sha256:loan-off-child")
    end
  end

  # The host that changes nothing, at the facade and the Driver: every
  # answer below is the one 0.25.1 gives on this backend.
  describe "the facade and the Driver with the linkage columns option left off" do
    # sabotage: answered `true` from Storage.linkage_supported?/1 for every
    # store -> red, the child was stored. Verified red, reverted from a copy.
    test "a durable child, the cascade and the tree read still refuse" do
      store = sqlite_store()
      parent = "execution_loan_off_driver"
      ref = attach_cascade_handler()

      driver = linked_driver(store, @cancelling_parent_source, subchart_dispatch())
      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      child = Linkage.child_execution_id(parent, "call", 0)
      assert {:error, :execution_not_found} = Storage.fetch_execution(store, child)

      assert {:error, :child_listing_unsupported} =
               Executions.cascade_cancel(store, Linkage.parent_match(parent),
                 serialization: {PassThroughSerialization, nil}
               )

      assert {:error, :child_listing_unsupported} =
               Executions.migrate_tree(store, parent, %{},
                 serialization: {PassThroughSerialization, nil}
               )

      assert {:ok, _execution, _machine_state} =
               Driver.send_event(driver, parent, Event.external("timeout"))

      refute_received {^ref, _measurements, _metadata}
    end
  end

  describe "V09 on this adapter" do
    # sabotage: built V09's content-hash index on linkage_invoke_id -> red here
    # on the index's column list, and red on its Postgres twin in
    # MigrationsTest. Verified red, reverted from a copy.
    test "the six linkage columns and their two indexes arrive here too" do
      columns = columns("sq_executions")

      for column <- ~w(linkage_parent_execution_id linkage_invoke_id linkage_child_index
                       linkage_content_hash linkage_child_count linkage_policy) do
        assert column in columns
        refute column in not_null_columns("sq_executions")
      end

      indexes = indexes("sq_executions")

      assert "sq_executions_linkage_parent_index" in indexes
      assert "sq_executions_linkage_content_hash_index" in indexes

      assert index_columns("sq_executions_linkage_parent_index") ==
               ["linkage_parent_execution_id", "linkage_invoke_id"]

      assert index_columns("sq_executions_linkage_content_hash_index") == [
               "linkage_content_hash"
             ]
    end
  end

  describe "the linkage columns option on, on this adapter" do
    # sabotage: made Storage.Ecto.supports_linkage?/1 answer false -> red on
    # its first assertion. Verified red, reverted from a copy.
    test "the store declares linkage and still declares no metadata" do
      store = linked_store()

      assert Storage.Ecto.supports_linkage?(store.opts)
      assert Storage.linkage_supported?(store)
      refute Storage.metadata_supported?(store)
      assert Enum.count(LinkedHost.Execution.__schema__(:fields), &linkage_field?/1) == 6
    end

    # sabotage: kept the reserved key in the metadata the insert stores -> red
    # on the stored metadata. Verified red, reverted from a copy.
    test "an insert stores the linkage in the columns and a fetch hands it back under the key" do
      opts = linked_store().opts
      parent = "execution_loan_insert"
      linkage = Linkage.new(parent, "renewals", 1, "sha256:loan-renewal", 3, :first_error)
      child = Linkage.child_execution_id(parent, "renewals", 1)
      metadata = Map.put(Linkage.to_metadata(linkage), "branch", "east")

      :ok = Storage.Ecto.insert_execution(opts, raw_record(child, %{metadata: metadata}))

      assert %{rows: [[stored | columns]]} =
               SQL.query!(
                 SqliteTestRepo,
                 "SELECT metadata, linkage_parent_execution_id, linkage_invoke_id, " <>
                   "linkage_child_index, linkage_content_hash, linkage_child_count, " <>
                   "linkage_policy FROM sq_executions WHERE execution_id = ?1",
                 [child]
               )

      assert JSON.decode!(stored) == %{"branch" => "east"}
      assert columns == [parent, "renewals", 1, "sha256:loan-renewal", 3, "first_error"]

      assert {:ok, %{metadata: ^metadata}} = Storage.Ecto.fetch_execution(opts, child)
      assert {:ok, ^linkage} = Linkage.from_metadata(metadata)
    end

    # sabotage: dropped with_linkage/2's no-linkage clause, so a plain row came
    # back with an empty reserved map -> red on `metadata == %{}`. Verified
    # red, reverted from a copy.
    test "a record with no linkage keeps its metadata and its columns stay empty" do
      opts = linked_store().opts
      execution_id = "execution_loan_plain"

      :ok = Storage.Ecto.insert_execution(opts, raw_record(execution_id))

      assert %{rows: [[nil, nil]]} =
               SQL.query!(
                 SqliteTestRepo,
                 "SELECT metadata, linkage_parent_execution_id FROM sq_executions " <>
                   "WHERE execution_id = ?1",
                 [execution_id]
               )

      assert {:ok, %{metadata: metadata}} = Storage.Ecto.fetch_execution(opts, execution_id)
      assert metadata == %{}
    end

    # sabotage: let linkage_column_values/1 skip a pair its columns cannot
    # hold -> red on the unknown-key insert, which stored. Verified red,
    # reverted from a copy.
    test "a reserved value the columns cannot hold is refused at open and writes nothing" do
      opts = linked_store().opts
      reserved = Linkage.reserved_key()

      for {suffix, value} <- [
            {"no_parent", %{"invoke_id" => "renewals"}},
            {"unknown_key", %{"parent_execution_id" => "execution_loan_x", "branch" => "east"}},
            {"wrong_type", %{"parent_execution_id" => "execution_loan_x", "child_index" => "0"}},
            {"not_a_map", "execution_loan_x"}
          ] do
        execution_id = "execution_loan_refused_" <> suffix

        assert {:error, :metadata_unsupported} =
                 Storage.Ecto.insert_execution(
                   opts,
                   raw_record(execution_id, %{metadata: %{reserved => value}})
                 )

        assert {:error, :execution_not_found} = Storage.Ecto.fetch_execution(opts, execution_id)
      end
    end

    # sabotage: let linkage_condition/2 drop a pair its columns cannot hold
    # -> red on the unknown-key match, which listed the children. Verified
    # red, reverted from a copy.
    test "the two listings answer a match on the reserved key by equality on the columns" do
      opts = linked_store().opts
      parent = "execution_loan_list"

      for {invoke_id, index} <- [{"renewals", 0}, {"renewals", 1}, {"holds", 0}] do
        linkage = Linkage.new(parent, invoke_id, index, "sha256:loan-list")

        :ok =
          Storage.Ecto.insert_execution(
            opts,
            raw_record(Linkage.child_execution_id(parent, invoke_id, index), %{
              metadata: Linkage.to_metadata(linkage)
            })
          )
      end

      :ok =
        Storage.Ecto.insert_execution(
          opts,
          raw_record("execution_loan_list_other/renewals/0", %{
            metadata:
              Linkage.to_metadata(
                Linkage.new("execution_loan_list_other", "renewals", 0, "sha256:loan-list")
              )
          })
        )

      assert {:ok, children} =
               Storage.Ecto.list_executions_by_metadata(opts, Linkage.parent_match(parent))

      assert children |> Enum.map(& &1.execution_id) |> Enum.sort() == [
               parent <> "/holds/0",
               parent <> "/renewals/0",
               parent <> "/renewals/1"
             ]

      assert Enum.all?(children, &match?({:ok, _linkage}, Linkage.from_metadata(&1.metadata)))

      assert {:ok, states} =
               Storage.Ecto.list_execution_states_by_metadata(
                 opts,
                 Linkage.invocation_match(parent, "renewals")
               )

      assert Enum.sort_by(states, & &1.child_index) == [
               %{execution_id: parent <> "/renewals/0", status: :active, child_index: 0},
               %{execution_id: parent <> "/renewals/1", status: :active, child_index: 1}
             ]

      reserved = Linkage.reserved_key()

      # A pair no stored linkage can hold matches nothing, as containment
      # would answer it.
      assert {:ok, []} =
               Storage.Ecto.list_executions_by_metadata(opts, %{
                 reserved => %{"parent_execution_id" => parent, "child_index" => "0"}
               })

      assert {:ok, []} =
               Storage.Ecto.list_executions_by_metadata(opts, %{
                 reserved => %{"parent_execution_id" => parent, "branch" => "east"}
               })

      # A host key is still metadata this store does not hold.
      assert {:error, :metadata_unsupported} =
               Storage.Ecto.list_executions_by_metadata(opts, %{"branch" => "east"})

      assert {:error, :metadata_unsupported} =
               Storage.Ecto.list_execution_states_by_metadata(
                 opts,
                 Map.put(Linkage.parent_match(parent), "branch", "east")
               )
    end

    # sabotage: made column_linkage_update/3 write nothing for a linked row ->
    # red on the re-pinned hash. Verified red, reverted from a copy.
    test "a step's update carries the columns forward and a re-pin rewrites the pin" do
      opts = linked_store().opts
      parent = "execution_loan_repin"
      linkage = Linkage.new(parent, "renewals", 0, "sha256:loan-repin-old")
      child = Linkage.child_execution_id(parent, "renewals", 0)
      record = raw_record(child, %{metadata: Linkage.to_metadata(linkage)})

      :ok = Storage.Ecto.insert_execution(opts, record)
      :ok = Storage.Ecto.update_execution(opts, %{record | position_blob: "stepped"})

      assert {:ok, %{metadata: metadata, position_blob: "stepped"}} =
               Storage.Ecto.fetch_execution(opts, child)

      assert metadata == Linkage.to_metadata(linkage)

      :ok =
        Storage.Ecto.write_tree_migration(opts, [
          {:repin, %{record | content_hash: "sha256:loan-repin-new"}, "sha256:loan-repin-new"}
        ])

      assert {:ok, %{metadata: repinned}} = Storage.Ecto.fetch_execution(opts, child)

      assert {:ok, %Linkage{content_hash: "sha256:loan-repin-new", invoke_id: "renewals"}} =
               Linkage.from_metadata(repinned)
    end

    # sabotage: put children_pin_count/2 back on supports_metadata?/1 alone ->
    # red on `children: 1`. Verified red, reverted from a copy.
    test "the pin count reads the columns while the parent pins" do
      opts = linked_store().opts
      parent = "execution_loan_pins"
      pin = "sha256:loan-pins-child"
      child = Linkage.child_execution_id(parent, "renewals", 0)

      :ok = Storage.Ecto.insert_execution(opts, raw_record(parent))

      :ok =
        Storage.Ecto.insert_execution(
          opts,
          raw_record(child, %{
            content_hash: "sha256:loan-pins-elsewhere",
            metadata: Linkage.to_metadata(Linkage.new(parent, "renewals", 0, pin))
          })
        )

      :ok =
        Storage.Ecto.save_chart(opts, %{
          content_hash: pin,
          identity_blob: "identity-bytes",
          chart_blob: "chart-bytes"
        })

      assert {:ok, %{children: 1, active: 0}} =
               Storage.Ecto.count_executions_by_content_hash(opts, pin)

      assert {:error, {:pinned, %{children: 1}}} =
               Storage.Ecto.retire_chart(opts, pin, %{
                 retired_at: DateTime.utc_now(),
                 retired_by: "ops@example.test",
                 sources: %{}
               })

      :ok = Storage.Ecto.update_execution(opts, raw_record(parent, %{status: :completed}))

      assert {:ok, %{children: 0}} = Storage.Ecto.count_executions_by_content_hash(opts, pin)
    end
  end

  # ADR-0008's 2026-11-19 Amendment, the facade and Driver half, on this
  # adapter: the same doors `DriverSubchartEctoTest` and
  # `DriverFanoutEctoTest` drive on Postgres, for the host that opts in.
  # Every case passes `PassThroughSerialization`, the strategy the
  # Amendment's point 6 leaves to such a host.
  describe "durable subchart children with the linkage columns option on" do
    # sabotage: dropped the linkage_supported?/1 arm from Storage's
    # check_metadata_supported/2 -> red on the first check_metadata/2;
    # and let a match naming a host key through to the adapter -> red on
    # `:child_listing_unsupported`, which answered the adapter's own
    # `:metadata_unsupported`. Each verified red, reverted from a copy.
    test "the facade admits the reserved key alone and still refuses a host key" do
      store = linked_store()
      linkage = Linkage.new("execution_loan_facade", "renewals", 0, "sha256:loan-facade")
      reserved = Linkage.to_metadata(linkage)
      host_key = %{"branch" => "east"}

      assert :ok = Storage.check_metadata(store, metadata: reserved)
      assert :ok = Storage.check_metadata(store, metadata: %{})

      assert {:error, :metadata_unsupported} = Storage.check_metadata(store, metadata: host_key)

      assert {:error, :metadata_unsupported} =
               Storage.check_metadata(store, metadata: Map.merge(reserved, host_key))

      assert Storage.child_listing_supported?(store)
      assert Storage.execution_states_supported?(store)

      match = Linkage.parent_match("execution_loan_facade")
      assert {:ok, []} = Storage.list_executions_by_metadata(store, match)
      assert {:ok, []} = Storage.list_execution_states_by_metadata(store, match)

      for refused <- [host_key, Map.merge(match, host_key), %{}] do
        assert {:error, :child_listing_unsupported} =
                 Storage.list_executions_by_metadata(store, refused)

        assert {:error, :execution_states_unsupported} =
                 Storage.list_execution_states_by_metadata(store, refused)
      end
    end

    # sabotage: put Storage.child_listing_supported?/1 back on
    # metadata_supported?/1 alone -> red on the child listing, and on every
    # other case in this block. Verified red, reverted from a copy.
    test "a single child is created, listed and answers its parent" do
      store = linked_store()
      parent = "execution_loan_single"
      driver = linked_driver(store, @parent_source, subchart_dispatch())

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      child = Linkage.child_execution_id(parent, "call", 0)

      assert {:ok, [%{execution_id: ^child, status: :active}]} =
               Storage.list_executions_by_metadata(store, Linkage.parent_match(parent))

      assert {:ok, _execution, _machine_state} =
               Driver.send_event(child_driver(store), child, Event.external("go"))

      assert {:ok, %{status: :completed}} = Storage.fetch_execution(store, child)
      assert leaves(reload(store, @parent_source, parent)) == ["approved"]
    end

    # ADR-0008's 2026-11-22 Amendment with the linkage in the columns: a
    # later pass's id is the only new thing a loop writes, and it is an
    # execution id, so the six columns hold every pass's linkage as they are.
    # sabotage: in Driver's first_child/2, adopted a child at the first id
    # whatever its status (the 0.26.0 rule) -> red on SQLite, one child
    # listed where two were asserted. Verified red, reverted from a copy.
    test "two passes of a loop start two children in order and the parent goes on" do
      store = linked_store()
      parent = "execution_loan_renewals_sqlite_1"
      driver = loop_driver(store)
      first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
      assert LoopingSubchart.children(store, parent) == [{first, :active}]

      assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)
      assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)
      assert String.starts_with?(second, first <> "@")

      assert {:ok, %{status: :completed}, _machine_state} =
               LoopingSubchart.approve(driver, second)

      assert LoopingSubchart.leaves(store, "myapp:map", parent) == ["renewed_all"]
    end

    # sabotage: in Driver's later_pass/5, refused a child found at the later
    # pass's id instead of adopting it -> red on SQLite, the refusal sent
    # the parent to "refused", whose exit cancelled the second pass's
    # child. Verified red, reverted from a copy.
    test "a re-drive of a loop's second pass adopts its child" do
      store = linked_store()
      parent = "execution_loan_renewals_sqlite_2"
      driver = loop_driver(store)
      first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)
      before_second_pass = LoopingSubchart.record(store, parent)

      assert {:ok, %{status: :completed}, _machine_state} = LoopingSubchart.approve(driver, first)
      assert [{^first, :completed}, {second, :active}] = LoopingSubchart.children(store, parent)

      :ok = LoopingSubchart.lose_step(store, before_second_pass)

      assert {:ok, _execution, _machine_state} =
               Driver.answer_parent(driver, first, {:done, nil})

      assert [{^first, :completed}, {^second, :active}] = LoopingSubchart.children(store, parent)
      assert LoopingSubchart.leaves(store, "myapp:map", parent) == ["renewing"]
    end

    # sabotage: put Storage.execution_states_supported?/1 back on
    # metadata_supported?/1 alone -> red, start_child_at/6 refused
    # `:execution_states_unsupported`. Verified red, reverted from a copy.
    test "a fan-out's children are created, settled and answer their parent" do
      store = linked_store()
      parent = "execution_loan_fanout"
      driver = start_linked_parent(store, parent)

      for index <- 0..1 do
        assert :ok = Driver.start_child_at(driver, parent, effect(), index, 2)
      end

      assert {:ok, states} =
               Storage.list_execution_states_by_metadata(
                 store,
                 Linkage.invocation_match(parent, "call")
               )

      assert states |> Enum.map(& &1.child_index) |> Enum.sort() == [0, 1]

      for index <- 0..1 do
        child = Linkage.child_execution_id(parent, "call", index)

        assert {:ok, _execution, _machine_state} =
                 Driver.send_event(child_driver(store), child, Event.external("go"))
      end

      assert leaves(reload(store, @parent_source, parent)) == ["approved"]
    end

    # sabotage: in Driver's `:cancel_invoke` arm, answered `:ok` without the
    # cascade -> red on the child's status. Verified red, reverted from a
    # copy.
    test "leaving the invoking state cancels the child and keeps its position" do
      store = linked_store()
      parent = "execution_loan_cancel"
      driver = linked_driver(store, @cancelling_parent_source, subchart_dispatch())

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      child = Linkage.child_execution_id(parent, "call", 0)
      assert {:ok, before} = Storage.fetch_execution(store, child)

      assert {:ok, _execution, machine_state} =
               Driver.send_event(driver, parent, Event.external("timeout"))

      assert leaves(machine_state) == ["abandoned"]

      assert {:ok, %{status: :cancelled, position_blob: position_blob}} =
               Storage.fetch_execution(store, child)

      assert position_blob == before.position_blob
    end

    # sabotage: answered `{:error, :child_listing_unsupported}` from
    # Storage.list_executions_by_metadata/2 for every match -> red on the
    # first call. Verified red, reverted from a copy.
    test "cascade_cancel/3 and migrate_tree/4 read the children instead of refusing" do
      store = linked_store()
      parent = "execution_loan_tree"
      driver = linked_driver(store, @cancelling_parent_source, subchart_dispatch())

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      assert {:ok, []} =
               Executions.migrate_tree(store, parent, %{},
                 serialization: {PassThroughSerialization, nil}
               )

      assert {:ok, 1} =
               Executions.cascade_cancel(store, Linkage.parent_match(parent),
                 serialization: {PassThroughSerialization, nil}
               )
    end

    # sabotage: same mutation as the case above -> red, no event arrived;
    # and the `:cancel_invoke` arm's mutation two cases up -> red the same
    # way. Each verified red, reverted from a copy.
    test "an invoke's exit with no durable child now queries and reports zero" do
      store = linked_store()
      parent = "execution_loan_plain_exit"
      ref = attach_cascade_handler()

      driver =
        linked_driver(store, @cancelling_parent_source, fn _type, _params, _ctx -> :pending end)

      assert {:ok, _execution, _machine_state} = Driver.create(driver, parent)

      assert {:ok, _execution, _machine_state} =
               Driver.send_event(driver, parent, Event.external("timeout"))

      assert_received {^ref, %{count: 0, retained: 0}, %{parent_execution_id: ^parent}}
    end

    # sabotage: dropped the status filter from Executions.active_children/2
    # -> red, the completed child came back; and sorted by execution id in
    # place of invocation id and index -> red, child 10 came before child 2.
    # Each verified red, reverted from a copy.
    test "active_children/2 reads the children from the linkage columns" do
      store = linked_store()
      parent = "execution_loan_active_children"
      driver = start_linked_parent(store, parent)

      for index <- [10, 2, 3] do
        assert :ok = Driver.start_child_at(driver, parent, effect(), index, 11)
      end

      third = Linkage.child_execution_id(parent, "call", 3)

      assert {:ok, _execution, _machine_state} =
               Driver.send_event(child_driver(store), third, Event.external("go"))

      assert {:ok, children} = Executions.active_children(store, parent)

      assert Enum.map(children, &{&1.execution_id, &1.status}) == [
               {Linkage.child_execution_id(parent, "call", 2), :active},
               {Linkage.child_execution_id(parent, "call", 10), :active}
             ]

      assert {:ok, []} = Executions.active_children(store, third)
    end
  end

  defp event(name), do: %Event{name: name, type: :external}

  defp logged_execution(store, execution_id) do
    {:ok, machine} = Statifier.compile(@child_source)
    machine_state = MachineState.new(machine, session_id: "sess_" <> execution_id)

    :ok = Storage.insert_execution(store, execution_id, machine_state, :active)

    execution_id
  end

  defp loop_driver(store) do
    LoopingSubchart.driver(store, "myapp:map", serialization: {PassThroughSerialization, nil})
  end

  defp linked_store do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: LinkedHost)
    store
  end

  defp linked_driver(store, source, dispatch, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [
          dispatch: dispatch,
          invoke_types: InvokeTypes.new(types: ["myapp:map"]),
          serialization: {PassThroughSerialization, nil}
        ],
        opts
      )
    )
  end

  defp start_linked_parent(store, execution_id) do
    driver =
      linked_driver(store, @parent_source, fn "myapp:map", _params, _context -> :pending end)

    {:ok, _execution, _machine_state} = Driver.create(driver, execution_id)
    driver
  end

  # A driver over the child's chart that can reach the parent's chart, the
  # shape every node answering a durable child has.
  defp child_driver(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    parent_hash = Machine.identity(parent_machine).content_hash

    resolver = fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end

    linked_driver(store, @child_source, fn _type, _params, _context -> :pending end,
      chart_resolver: resolver
    )
  end

  defp subchart_dispatch do
    fn "myapp:map", _params, %{invoke_id: invoke_id} ->
      invoke = %{effect() | invoke_id: invoke_id}
      {:start_child, invoke, {:invoke, invoke}}
    end
  end

  defp reload(store, source, execution_id) do
    {:ok, machine} = Statifier.compile(source)
    {:ok, machine_state} = Storage.load_execution_position(store, execution_id, machine)
    machine_state
  end

  defp parent_resolver do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end

  defp leaves(machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  defp attach_cascade_handler do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:statifier_persistence, :child, :cascade_cancelled],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # A stored execution in the adapter's own record shape, for the cases
  # that drive the callbacks directly.
  defp raw_record(execution_id, overrides \\ %{}) do
    Map.merge(
      %{
        execution_id: execution_id,
        status: :active,
        content_hash: "sha256:loan-chart",
        identity_blob: "identity-bytes",
        position_blob: "position-bytes",
        failure: nil,
        metadata: %{},
        outcome_blob: nil,
        ended_at: nil
      },
      overrides
    )
  end

  defp linkage_field?(field), do: field |> Atom.to_string() |> String.starts_with?("linkage_")

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

  # PRAGMA index_info's third column is the indexed column's name.
  defp index_columns(index) do
    %{rows: rows} = SQL.query!(SqliteTestRepo, "PRAGMA index_info(#{index})", [])
    Enum.map(rows, fn row -> Enum.at(row, 2) end)
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
