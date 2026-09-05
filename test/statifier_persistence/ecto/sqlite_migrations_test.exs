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
  raises.

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
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.SqliteTestRepo
  alias StatifierPersistence.SqliteTestRepo.Host

  defmodule MigrateSqlite do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.SqliteTestRepo.Host)
    def down, do: Migrations.down(for: StatifierPersistence.SqliteTestRepo.Host)
  end

  # A pass-through per-run exclusion. `Storage.Ecto.lock_run/3` is
  # `pg_advisory_xact_lock` plus `FOR UPDATE` and raises on SQLite, which
  # is sp-5lm's separate Postgres-only surface and not what these cases
  # are about: the fan-out gate below has to be reached to be observed,
  # and reaching it must not depend on a lock this bead does not fix.
  defmodule PassThroughSerialization do
    @moduledoc false

    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_run(_config, _run_id, fun), do: {:ok, fun.()}
  end

  @migration_version 20_260_905_000_201

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
    # run ended "6 tests, 0 failures, 6 invalid" - the rolled-back
    # migration left no tables for any case in this module. Verified red,
    # reverted.
    test "V01 through V03 apply, and the runs table carries every column" do
      assert tables() == ["sq_charts", "sq_positions", "sq_runs"]

      columns = columns("sq_runs")

      assert "metadata" in columns
      assert "outcome_blob" in columns
      assert "run_id" in columns
      assert "status" in columns
    end

    # sabotage: covered by the same run as the case above - with the guard
    # replaced by `true` this case never executes, because creating the
    # index is what makes setup_all raise. That the index cannot exist
    # here is exactly what it asserts. Verified red (invalid), reverted.
    test "no index on metadata is created" do
      refute Enum.any?(indexes("sq_runs"), &String.contains?(&1, "metadata"))
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

      assert tables() == ["sq_charts", "sq_positions", "sq_runs"]
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
      refute Storage.run_states_supported?(store)

      match = Linkage.invocation_match("run_sqlite_absent", "call")

      assert {:error, :child_listing_unsupported} =
               Storage.list_runs_by_metadata(store, match)

      assert {:error, :run_states_unsupported} =
               Storage.list_run_states_by_metadata(store, match)
    end

    # sabotage: dropped the metadata_supported?/1 conjunct from
    # Storage.child_listing_supported?/1 alone -> red, and instructively:
    # the fan-out got past the listing arm and refused
    # `:run_states_unsupported` from the next one instead, which is the
    # projection's own conjunct holding. Verified red, reverted.
    test "a fan-out over this store is refused at open, not started" do
      store = sqlite_store()
      driver = start_parent(store, "run_sqlite_fanout")

      assert {:refused, :child_listing_unsupported} =
               Driver.start_child_at(driver, "run_sqlite_fanout", effect(), 0, 2)

      assert {:error, :run_not_found} =
               Storage.fetch_run(store, Linkage.child_run_id("run_sqlite_fanout", "call", 0))
    end

    # sabotage: made Storage.Ecto.supports_run_outcome?/1 answer the same
    # adapter check supports_metadata?/1 does -> red ("Expected truthy,
    # got false"). The column exists on every adapter, and declaring
    # otherwise contradicts the migration case above. Verified red,
    # reverted.
    test "run outcome support is still declared: outcome_blob exists here" do
      assert Storage.run_outcome_supported?(sqlite_store())
    end
  end

  defp sqlite_store do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Host)
    store
  end

  defp start_parent(store, run_id) do
    {:ok, machine} = Statifier.compile(@parent_source)

    driver =
      Driver.new(store, machine,
        dispatch: fn "myapp:map", _params, _context -> :pending end,
        invoke_types: InvokeTypes.new(types: ["myapp:map"]),
        serialization: {PassThroughSerialization, nil}
      )

    {:ok, _run, _machine_state} = Driver.create(driver, run_id)
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
  # database; leaving either behind would carry state into the next run.
  defp remove_database(database) do
    for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    :ok
  end
end
