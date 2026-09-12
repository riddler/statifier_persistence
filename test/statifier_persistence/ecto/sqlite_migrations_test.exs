defmodule StatifierPersistence.Ecto.SqliteMigrationsTest do
  @moduledoc """
  The versioned migration helper, and the Ecto adapter's metadata
  declaration, on an Ecto adapter that is not Postgres (sp-11w).

  0.7.0 could not be adopted by a SQLite host at all: V03's `GIN`
  `jsonb_path_ops` index made `ecto_sqlite3` raise, which rolled the whole
  migration back and took the `outcome_blob` column with it, and capping at
  V02 was equally dead because the generated runs schema reads
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

  @concurrent_version 20_260_906_000_401

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
    test "V01 through V05 apply, and the executions table carries every column" do
      assert tables() == ["sq_charts", "sq_inputs", "sq_positions", "sq_runs"]

      columns = columns("sq_runs")

      assert "metadata" in columns
      assert "outcome_blob" in columns
      assert "run_id" in columns
      assert "status" in columns
    end

    # sabotage: covered by the same execution as the case above - with the guard
    # replaced by `true` this case never executes, because creating the
    # index is what makes setup_all raise. That the index cannot exist
    # here is exactly what it asserts. Verified red (invalid), reverted.
    test "no index on metadata is created" do
      refute Enum.any?(indexes("sq_runs"), &String.contains?(&1, "metadata"))
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

      refute Enum.any?(indexes("sq_runs"), &String.contains?(&1, "metadata"))
      assert "outcome_blob" in columns("sq_runs")

      :ok = migrate_capped(:down, @concurrent_version, MigrateSqliteConcurrentV04)

      refute Enum.any?(indexes("sq_runs"), &String.contains?(&1, "metadata"))
      assert tables() == ["sq_charts", "sq_inputs", "sq_positions", "sq_runs"]
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
      assert Migrations.expected_version() == 5
    end

    # sabotage: replaced V03.down/1's postgres?() guard with `true`, so
    # down/1 drops an index that was never created -> red, this case alone
    # ("6 tests, 1 failure") with
    # `** (Exqlite.Error) no such index: sq_runs_metadata_gin_index`.
    # Verified red, reverted.
    test "down/1 rolls the whole DDL back and up/1 puts it back" do
      :ok = migrate(:down)

      assert tables() == []

      :ok = migrate(:up)

      assert tables() == ["sq_charts", "sq_inputs", "sq_positions", "sq_runs"]
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
        SQL.query!(SqliteTestRepo, "DROP TABLE IF EXISTS sq_cap_runs", [])
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
               ["sq_cap_charts", "sq_cap_inputs", "sq_cap_positions", "sq_cap_runs"]

      assert "outcome_blob" in columns("sq_cap_runs")

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

  defp tables do
    %{rows: rows} =
      SQL.query!(
        SqliteTestRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sq_%' ORDER BY name",
        []
      )

    List.flatten(rows)
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
