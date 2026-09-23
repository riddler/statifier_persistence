defmodule StatifierPersistence.Ecto.LeadingColumnsTest do
  # Live DDL outside the SQL sandbox, like migrations_test.exs: the module
  # switches the repo to :auto for its own tables and restores :manual on
  # exit, hence async: false.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierPersistence.Ecto.Config
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.TestRepo

  # A library host that keys every row by the branch that owns it: two
  # host-owned columns, in the order it wants them.
  defmodule BranchHost do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      table_prefix: "lc_",
      leading_columns: [tenant_id: {:text, null: true}, branch_id: {:bigint, []}]
  end

  defmodule MigrateBranchHost do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.Ecto.LeadingColumnsTest.BranchHost)
    def down, do: Migrations.down(for: StatifierPersistence.Ecto.LeadingColumnsTest.BranchHost)
  end

  @version 20_260_923_000_001

  @tables ["lc_charts", "lc_executions", "lc_inputs", "lc_positions"]

  setup do
    Sandbox.mode(TestRepo, :auto)

    on_exit(fn ->
      for table <- @tables do
        SQL.query!(TestRepo, ~s(DROP TABLE IF EXISTS "#{table}"), [])
      end

      SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = $1", [@version])
      Sandbox.mode(TestRepo, :manual)
    end)

    :ok
  end

  describe "the migrations helper" do
    # sabotage: dropped the add_leading_columns(config) call from V01's
    # executions block -> red here, lc_executions came back as id,
    # execution_id, status. Verified red, reverted.
    # sabotage: moved V05's leading-columns `for` below add(:door, ...) ->
    # red here, lc_inputs came back as id, execution_id, seq. Verified red,
    # reverted.
    test "places each leading column right after id, in order, on all four tables" do
      :ok = Migrator.up(TestRepo, @version, MigrateBranchHost, log: false)

      for table <- @tables do
        assert leading(table) == [{"id", 1}, {"tenant_id", 2}, {"branch_id", 3}],
               "#{table}: #{inspect(leading(table))}"
      end
    end

    # sabotage: made V05.down/1 a no-op -> red here, the rollback left
    # ["lc_inputs"] behind. Verified red, reverted.
    test "rolls back to no table at all" do
      :ok = Migrator.up(TestRepo, @version, MigrateBranchHost, log: false)
      assert tables_like("lc_") == @tables

      :ok = Migrator.down(TestRepo, @version, MigrateBranchHost, log: false)
      assert tables_like("lc_") == []
    end

    # sabotage: made V01's add_leading_columns/1 force null: false on every
    # column -> red here, the chart insert through the generated schema
    # raised not_null_violation on tenant_id. Verified red, reverted.
    test "the package's own writes leave the host's columns alone" do
      :ok = Migrator.up(TestRepo, @version, MigrateBranchHost, log: false)

      chart =
        TestRepo.insert!(%BranchHost.Chart{
          content_hash: "sha256:lc-loan",
          identity_blob: "identity",
          chart_blob: "<scxml/>"
        })

      assert %{rows: [[nil, nil]]} =
               SQL.query!(TestRepo, "SELECT tenant_id, branch_id FROM lc_charts WHERE id = $1", [
                 chart.id
               ])

      refute :tenant_id in BranchHost.Chart.__schema__(:fields)
    end
  end

  describe "the option" do
    # sabotage: hardcoded `leading_columns: []` in Config.new/1, ignoring
    # the option -> red here on BranchHost's configuration (and on every
    # other case in this module). Verified red, reverted.
    test "defaults to no leading columns and keeps the configured order" do
      assert %Config{leading_columns: []} = Default.__statifier_persistence__(:config)

      assert %Config{leading_columns: [tenant_id: {:text, null: true}, branch_id: {:bigint, []}]} =
               BranchHost.__statifier_persistence__(:config)
    end

    # sabotage: hardcoded `leading_columns: []` in Config.new/1 -> red
    # here, the literal-options configuration came back empty. Verified
    # red, reverted.
    test "accepts name: {type, opts} through the literal-options door" do
      assert %Config{leading_columns: [tenant_id: {:text, null: true}]} =
               Config.new(repo: TestRepo, leading_columns: [tenant_id: {:text, null: true}])
    end

    # sabotage: made validate_leading_columns!/1 return its argument
    # unchecked -> red here, nothing raised for the first malformed
    # spelling. Verified red, reverted.
    test "rejects a malformed spelling at configuration time" do
      for bad <- [
            :tenant_id,
            [{"tenant_id", {:text, []}}],
            [tenant_id: :text],
            [tenant_id: {:text, [:null]}],
            [tenant_id: {:text, []}, tenant_id: {:bigint, []}]
          ] do
        assert_raise ArgumentError, ~r/:leading_columns/, fn ->
          Config.new(repo: TestRepo, leading_columns: bad)
        end
      end
    end
  end

  defp leading(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT column_name, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND ordinal_position <= 3
        ORDER BY ordinal_position
        """,
        [table]
      )

    Enum.map(rows, fn [name, position] -> {name, position} end)
  end

  defp tables_like(prefix) do
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
end
