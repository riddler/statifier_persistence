defmodule StatifierPersistence.Ecto.MigrationsTest do
  # Live migration tests manage their own DDL and inserts outside the SQL
  # sandbox: setup_all switches the repo to :auto mode for the module and
  # restores :manual on exit, hence async: false.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias StatifierPersistence.Ecto.Migrations
  alias StatifierPersistence.EctoHosts.{KxBigserial, KxUuid, KxUxid}
  alias StatifierPersistence.TestRepo

  defmodule MigrateKxUxid do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.EctoHosts.KxUxid)
    def down, do: Migrations.down(for: StatifierPersistence.EctoHosts.KxUxid)
  end

  defmodule MigrateKxUuid do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.EctoHosts.KxUuid)
    def down, do: Migrations.down(for: StatifierPersistence.EctoHosts.KxUuid)
  end

  defmodule MigrateKxBigserial do
    use Ecto.Migration

    def up, do: Migrations.up(for: StatifierPersistence.EctoHosts.KxBigserial)
    def down, do: Migrations.down(for: StatifierPersistence.EctoHosts.KxBigserial)
  end

  # The literal-options door: the same options `use` takes, plus the
  # `prefix:` Postgres-schema knob.
  defmodule MigrateKxLiteral do
    use Ecto.Migration

    @opts [
      repo: StatifierPersistence.TestRepo,
      key: :uxid,
      table_prefix: "kx_lit_",
      prefix: "kx_schema"
    ]

    def up, do: Migrations.up(@opts)
    def down, do: Migrations.down(@opts)
  end

  @host_migrations [
    {20_260_822_000_001, MigrateKxUxid},
    {20_260_822_000_002, MigrateKxUuid},
    {20_260_822_000_003, MigrateKxBigserial}
  ]

  @literal_version 20_260_822_000_009

  @key_prefixes ["kx_uxid_", "kx_uuid_", "kx_big_"]

  setup_all do
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)

    for {version, module} <- @host_migrations do
      :ok = migrate(:up, version, module)
    end

    on_exit(fn ->
      for {version, module} <- Enum.reverse(@host_migrations) do
        :ok = migrate(:down, version, module)
      end
    end)

    :ok
  end

  defp migrate(direction, version, module) do
    case apply(Migrator, direction, [TestRepo, version, module, [log: false]]) do
      :ok -> :ok
      :already_up -> :ok
      :already_down -> :ok
    end
  end

  describe "rows through the generated schemas" do
    # sabotage: removed V01's charts chart_blob column -> inserts red (undefined column)
    test "uxid host: keys carry per-table prefixes, identities verbatim" do
      chart =
        TestRepo.insert!(%KxUxid.Chart{
          content_hash: "sha256:kx-uxid-chart",
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        })

      assert String.starts_with?(chart.id, "chart_")
      fetched = TestRepo.get!(KxUxid.Chart, chart.id)
      assert fetched.content_hash == "sha256:kx-uxid-chart"
      assert fetched.identity_blob == <<1, 2, 3>>
      assert fetched.chart_blob == <<4, 5, 6>>

      position =
        TestRepo.insert!(%KxUxid.Position{
          session_id: "sess-kx-uxid",
          content_hash: "sha256:kx-uxid-chart",
          identity_blob: <<1, 2, 3>>,
          position_blob: <<7, 8>>
        })

      assert String.starts_with?(position.id, "pos_")
      assert TestRepo.get!(KxUxid.Position, position.id).session_id == "sess-kx-uxid"

      run =
        TestRepo.insert!(%KxUxid.Run{
          run_id: "run-kx-uxid",
          status: "running",
          content_hash: "sha256:kx-uxid-chart",
          identity_blob: <<1, 2, 3>>
        })

      assert String.starts_with?(run.id, "run_")
      fetched_run = TestRepo.get!(KxUxid.Run, run.id)
      assert fetched_run.run_id == "run-kx-uxid"
      assert fetched_run.position_blob == nil
      assert fetched_run.failure == nil
      assert fetched_run.session_id == nil
    end

    # sabotage: hardcoded V01's pk_type to :text -> uuid insert red (type mismatch)
    test "uuid host: primary keys are UUIDv7, identities verbatim" do
      chart =
        TestRepo.insert!(%KxUuid.Chart{
          content_hash: "sha256:kx-uuid-chart",
          identity_blob: <<9>>,
          chart_blob: <<10>>
        })

      # Canonical form: the character at index 14 is the version nibble.
      assert String.at(chart.id, 14) == "7"
      assert {:ok, _} = Ecto.UUID.dump(chart.id)
      assert TestRepo.get!(KxUuid.Chart, chart.id).content_hash == "sha256:kx-uuid-chart"

      run =
        TestRepo.insert!(%KxUuid.Run{
          run_id: "run-kx-uuid",
          status: "completed",
          content_hash: "sha256:kx-uuid-chart",
          identity_blob: <<9>>
        })

      assert TestRepo.get!(KxUuid.Run, run.id).run_id == "run-kx-uuid"
    end

    # sabotage: hardcoded V01's pk_type to :text -> insert red (no db-assigned key)
    test "bigserial host: database assigns integer keys, identities verbatim" do
      chart =
        TestRepo.insert!(%KxBigserial.Chart{
          content_hash: "sha256:kx-big-chart",
          identity_blob: <<11>>,
          chart_blob: <<12>>
        })

      assert is_integer(chart.id)
      assert TestRepo.get!(KxBigserial.Chart, chart.id).content_hash == "sha256:kx-big-chart"

      position =
        TestRepo.insert!(%KxBigserial.Position{
          session_id: "sess-kx-big",
          content_hash: "sha256:kx-big-chart",
          identity_blob: <<11>>,
          position_blob: <<13>>
        })

      assert is_integer(position.id)
      assert TestRepo.get!(KxBigserial.Position, position.id).session_id == "sess-kx-big"
    end
  end

  describe "identity columns across key configurations" do
    # sabotage: made V01's runs content_hash :string (varchar) -> red on runs drift
    test "content_hash/session_id/run_id columns identical across all three" do
      # [column_name, data_type, is_nullable] per ADR-0002: identities are
      # text, verbatim; only runs.session_id is nullable (decision 5).
      for {table, expected} <- [
            {"charts", [["content_hash", "text", "NO"]]},
            {"positions", [["content_hash", "text", "NO"], ["session_id", "text", "NO"]]},
            {"runs",
             [
               ["content_hash", "text", "NO"],
               ["run_id", "text", "NO"],
               ["session_id", "text", "YES"]
             ]}
          ] do
        columns = Enum.map(expected, &hd/1)

        for prefix <- @key_prefixes do
          assert identity_columns(prefix <> table, columns) == expected,
                 "identity columns of #{prefix}#{table} drifted"
        end
      end
    end

    # sabotage: removed V01's charts/runs unique_index calls -> red
    test "unique indexes on the identity columns identical across all three" do
      for {table, unique_columns} <- [
            {"charts", [["content_hash"]]},
            {"positions", [["session_id"]]},
            {"runs", [["run_id"]]}
          ] do
        for prefix <- @key_prefixes do
          assert unique_index_columns(prefix <> table) == unique_columns
        end
      end
    end
  end

  describe "V02: the runs metadata column" do
    # sabotage: removed V02's alter/add of the metadata column -> red, and
    # red loudly: the generated runs schema declares the field, so every
    # test in this module failed on the missing column, this one included.
    # Verified red, reverted.
    test "is a nullable jsonb column on runs, across every key configuration" do
      for prefix <- @key_prefixes do
        assert identity_columns(prefix <> "runs", ["metadata"]) ==
                 [["metadata", "jsonb", "YES"]]
      end
    end

    # V02 itself still creates no index; V03 is what ships one, and the
    # assertion moved to "V03: ..." below with it (sp-t57, ruling C6).
  end

  describe "V03: the runs outcome column and the metadata index" do
    # sabotage: removed V03's alter/add of the outcome_blob column (from
    # up/1 and down/1 together, so the module's own cycle stayed clean)
    # -> red here and in the two schema-insert tests, which the generated
    # runs schema's declared field turns into a missing-column error.
    # Verified red, reverted.
    test "outcome_blob is a nullable bytea column on runs, across every key configuration" do
      for prefix <- @key_prefixes do
        assert identity_columns(prefix <> "runs", ["outcome_blob"]) ==
                 [["outcome_blob", "bytea", "YES"]]
      end
    end

    # sabotage: removed V03's create(index(...)) and its matching drop/1
    # -> red, the index list came back empty for every key configuration.
    # Verified red, reverted.
    test "metadata carries exactly one GIN jsonb_path_ops index" do
      for prefix <- @key_prefixes do
        table = prefix <> "runs"

        assert metadata_indexes(table) == [[table <> "_metadata_gin_index"]]
        assert metadata_index_definition(table) =~ "USING gin"
        assert metadata_index_definition(table) =~ "jsonb_path_ops"
      end
    end
  end

  describe "unique indexes enforced" do
    # sabotage: removed V01's charts unique_index -> duplicate insert red
    test "a duplicate content_hash insert violates the charts unique index" do
      TestRepo.insert!(%KxUxid.Chart{
        content_hash: "sha256:kx-dup-chart",
        identity_blob: <<1>>,
        chart_blob: <<2>>
      })

      assert_raise Ecto.ConstraintError, ~r/content_hash/, fn ->
        TestRepo.insert!(%KxUxid.Chart{
          content_hash: "sha256:kx-dup-chart",
          identity_blob: <<1>>,
          chart_blob: <<2>>
        })
      end
    end

    # sabotage: removed V01's runs unique_index -> duplicate insert red
    test "a duplicate run_id insert violates the runs unique index" do
      TestRepo.insert!(%KxUuid.Run{
        run_id: "run-kx-dup",
        status: "running",
        content_hash: "sha256:kx-dup",
        identity_blob: <<1>>
      })

      assert_raise Ecto.ConstraintError, ~r/run_id/, fn ->
        TestRepo.insert!(%KxUuid.Run{
          run_id: "run-kx-dup",
          status: "failed",
          content_hash: "sha256:kx-dup",
          identity_blob: <<1>>
        })
      end
    end
  end

  describe "the literal-options door and down" do
    # sabotage: made V01.down drop only charts -> red on leftover kx_lit_ tables
    test "literal options with a Postgres schema migrate up and down clean" do
      on_exit(fn ->
        SQL.query!(TestRepo, "DROP SCHEMA IF EXISTS kx_schema CASCADE", [])

        SQL.query!(TestRepo, "DELETE FROM schema_migrations WHERE version = $1", [
          @literal_version
        ])
      end)

      :ok = migrate(:up, @literal_version, MigrateKxLiteral)

      assert tables_in_schema("kx_schema", "kx_lit_") ==
               ["kx_lit_charts", "kx_lit_positions", "kx_lit_runs"]

      assert unique_index_columns("kx_lit_runs", "kx_schema") == [["run_id"]]

      :ok = migrate(:down, @literal_version, MigrateKxLiteral)

      assert tables_in_schema("kx_schema", "kx_lit_") == []

      # A plain (non-CASCADE) drop doubles as proof down left the schema empty.
      SQL.query!(TestRepo, ~s(DROP SCHEMA "kx_schema"), [])
    end
  end

  describe "option validation" do
    # sabotage: skipped parse!'s version validation -> red (KeyError, not ArgumentError)
    test "an unknown version raises before any DDL" do
      assert_raise ArgumentError, ~r/unknown migration version/, fn ->
        Migrations.up(for: KxUxid, version: 4)
      end

      assert_raise ArgumentError, ~r/unknown migration version/, fn ->
        Migrations.down(for: KxUxid, version: 0)
      end
    end

    # sabotage: dropped up/1's validate_version!(from, "from") call -> red
    # (KeyError from the @migrations fetch, not ArgumentError). Verified
    # red, reverted.
    test "an unknown from: raises before any DDL" do
      assert_raise ArgumentError, ~r/unknown migration from/, fn ->
        Migrations.up(for: KxUxid, from: 0)
      end
    end

    # sabotage: dropped up/1's from > target guard -> red, nothing raised
    # and the empty descending range ran no migration at all, which would
    # silently skip DDL a host believes it applied. Verified red, reverted.
    test "a from: above the target version raises rather than silently doing nothing" do
      assert_raise ArgumentError, ~r/does not roll back/, fn ->
        Migrations.up(for: KxUxid, from: 2, version: 1)
      end
    end

    # sabotage: made the for: clause swallow extra options -> red (nothing raised)
    test "for: combined with literal options raises" do
      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        Migrations.up(for: KxUxid, table_prefix: "kx_other_")
      end
    end

    # sabotage: skipped host_config!'s exported-function check -> red (UndefinedFunctionError)
    test "for: a module that did not use StatifierPersistence.Ecto raises" do
      assert_raise ArgumentError, ~r/does not use StatifierPersistence.Ecto/, fn ->
        Migrations.up(for: Enum)
      end
    end
  end

  defp metadata_indexes(table) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
          AND indexdef LIKE '%metadata%'
        ORDER BY indexname
        """,
        [table]
      )

    rows
  end

  defp metadata_index_definition(table) do
    %{rows: [[definition]]} =
      SQL.query!(
        TestRepo,
        """
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = $1
          AND indexdef LIKE '%metadata%'
        """,
        [table]
      )

    definition
  end

  defp identity_columns(table, columns) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
          AND column_name = ANY($2)
        ORDER BY column_name
        """,
        [table, columns]
      )

    rows
  end

  defp unique_index_columns(table, schema \\ "public") do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT array_agg(a.attname ORDER BY a.attname)
        FROM pg_index ix
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
        WHERE n.nspname = $1 AND t.relname = $2
          AND ix.indisunique AND NOT ix.indisprimary
        GROUP BY i.relname
        ORDER BY i.relname
        """,
        [schema, table]
      )

    Enum.map(rows, fn [columns] -> Enum.sort(columns) end)
  end

  defp tables_in_schema(schema, like_prefix) do
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = $1 AND table_name LIKE $2
        ORDER BY table_name
        """,
        [schema, like_prefix <> "%"]
      )

    List.flatten(rows)
  end
end
