if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V06 do
    @moduledoc """
    V06 of the package DDL: the conditional, in-place rename of the durable
    noun (ADR-0011 decision 3).

    `0.12.0` renames the thing this package stores from a *run* to an
    *execution*, everywhere: the modules, the adapter callbacks, the tables
    and the columns. V01-V05 are rewritten to the new noun, so a database
    built at `0.12.0` or later holds `statifier_executions` with an
    `execution_id` column and has never held anything else. A database this
    package built before `0.12.0` holds `statifier_runs` with a `run_id`
    column. This version is what brings the second kind of database to the
    first.

    ## Two databases, one version

    `up/1` asks the repo whether the resolved **old** table name is there.

    - **It is not** - the fresh install. Nothing is renamed; `up/1` is a
      no-op. V01 already created the execution names directly.
    - **It is** - the upgraded install. The table, both columns, the two
      unique indexes over them and (on Postgres) the `metadata` GIN index
      are renamed **in place**.

    Either way V06 is the version this package now expects
    (`StatifierPersistence.Ecto.Migrations.expected_version/0` answers `6`);
    the package writes no versions table and no marker row, so the map entry
    and the host's own `schema_migrations` timestamp are the whole of the
    record that it ran.

    **No data is copied.** Every statement here is a catalog operation - a
    table, column or index rename - and not one of them reads or writes a
    row. An upgraded install's stored ids are therefore untouched: rows
    written before `0.12.0` keep their `run_`-prefixed surrogate keys while
    new rows get `exec_`-prefixed ones, and both are valid opaque strings
    that coexist permanently (ADR-0011 decision 2).

    ## Each object is asked about separately

    The record's question - does the resolved old table name exist - is what
    tells the two installs apart, and it is asked first. Each individual
    rename is then guarded by the existence of the object it renames, which
    is what makes the version correct on the two shapes the question alone
    does not separate:

    - A host that gave a `tables:` override for this table has the same name
      on both sides of the rename, so the table rename is skipped and the
      column rename is what moves it forward.
    - A host that capped its migrations below V05 has no input log yet, so
      there is no `run_id` column there to rename; a host that capped below
      V03 has no GIN index.

    ## The probe runs late

    The existence check goes through `Ecto.Migration.execute/1`'s function
    form rather than running in the body of `up/1`, for the reason V04
    records: Ecto's migration runner queues a migration's commands and runs
    them at the end, so asking the database anything from the body of `up/1`
    reaches it before V01 has created the tables, on every fresh database. A
    queued function runs in order, after the DDL ahead of it.

    ## Adapters other than Postgres

    Renaming a table and renaming a column are ordinary SQL on both
    backends this package tests (ADR-0005's Postgres harness and the SQLite
    repo of sp-11w). Two things differ:

    - The `metadata` GIN index is Postgres-only - V03 creates it only there
      - so its rename is skipped off Postgres, under the same exact-match
      adapter check V03 and V04 use.
    - SQLite has no `ALTER INDEX ... RENAME TO`. Off Postgres the two unique
      indexes are therefore dropped and recreated under their new names,
      which is still no data copy: an index is derived structure, this
      package reads and writes no row to rebuild it, and the end state is
      the index V01 and V05 declare.

    ## What V06 does not rename: stored child linkage

    A durable subchart child carries its linkage to its parent in the
    `metadata` column, under the reserved key `"parent_run_id"` before
    `0.12.0` and `"parent_execution_id"` from `0.12.0` on
    (`StatifierPersistence.Execution.Linkage`). V06 renames **no stored
    value**, by decision: it is a catalog operation and nothing here reads
    or writes a row (ADR-0011 decision 3; the consequence below is item 1
    of that record's acceptance Note of 2026-09-13).

    The consequence, stated plainly rather than left to be discovered: a
    child that was **in flight** when the host upgraded still carries the
    old key, so `Linkage.from_metadata/1` answers `:no_linkage` for it and
    its completion no longer settles its parent's fan-out. A host therefore
    **drains its in-flight children before upgrading to `0.12.0`** - let
    every durable subchart child reach a terminal status under `0.11.x`,
    then upgrade. Children created at `0.12.0` or later carry the new key
    and are unaffected, and a completed child's stored metadata is history
    that nothing reads for linkage again.

    ## Rolling back

    `down/1` is a **no-op**, and that is a decision rather than an omission
    (item 2 of ADR-0011's acceptance Note of 2026-09-13). ADR-0011 decision 3
    describes the earlier design, in which `down/1` renamed back and a
    rollback below V06 on an upgraded install was therefore unsupported;
    that Note supersedes both halves of that bullet: the down is a no-op,
    and only a rollback to pre-`0.12.0` code stays unsupported.

    Under the full cutover there is nothing for it to restore. V01-V05 are
    rewritten to the execution names, so on `0.12.0` code every database
    this package can reach - fresh or upgraded - is on those names, and
    they are the names V01-V05 drop. Renaming back would only be
    meaningful under a *downgrade to pre-`0.12.0` code*, and that is
    exactly what the record declares unsupported: an install that must
    return to the retired names restores from a backup, or migrates with
    `0.11.x`'s own migrations.

    Making it a no-op is also the only shape that survives the host
    migration pattern this package recommends. A host that writes one
    migration per package version rolls back one version per
    `Ecto.Migrator` step, so a rename back would run in its own step and
    the V05, V04, V03 and V01 steps behind it would then name objects that
    are no longer there. A condition inside a single
    `StatifierPersistence.Ecto.Migrations.down/1` call cannot see across
    those steps, which is the defect this ruling removes.

    So `down(for: Host, version: 6)` leaves the database exactly as it is,
    and a full `down(for: Host)` drops everything this package owns - on a
    fresh install and on an upgraded one alike, under one call or one call
    per version. The way down past V06 is a drop, not a downgrade.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @old_column "run_id"
    @new_column "execution_id"
    @old_table_name "runs"

    @doc """
    Renames the pre-`0.12.0` names to the execution names, in place, when
    this database still carries them; a no-op when it does not.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      execute(fn -> rename(config, old_executions_table(config), @old_column, @new_column) end)

      :ok
    end

    @doc """
    Does nothing. Rolling back below `0.12.0` code is unsupported, and
    V01-V05 drop the tables under the execution names either way - see the
    moduledoc.
    """
    @spec down(Config.t()) :: :ok
    def down(%Config{} = _config), do: :ok

    # The name the executions table has on the side of the rename we are
    # coming from. A host that gave a `tables:` override for this table
    # named it itself and keeps that name on both sides (ADR-0002 decisions
    # 3 and 4); everyone else has the table prefix plus the old noun.
    @spec old_executions_table(Config.t()) :: String.t()
    defp old_executions_table(%Config{} = config) do
      Map.get(config.tables, :executions, config.table_prefix <> @old_table_name)
    end

    @spec rename(Config.t(), String.t(), String.t(), String.t()) :: :ok
    defp rename(%Config{} = config, from_table, from_column, to_column) do
      repo = repo()
      to_table = to_table(config, from_table)

      if table_exists?(repo, config, from_table) do
        rename_table(repo, config, from_table, to_table)
        rename_column(repo, config, to_table, from_column, to_column)

        rename_unique_index(
          repo,
          config,
          to_table,
          "#{from_table}_#{from_column}_index",
          "#{to_table}_#{to_column}_index",
          [to_column]
        )

        inputs = Config.table(config, :inputs)
        rename_column(repo, config, inputs, from_column, to_column)

        rename_unique_index(
          repo,
          config,
          inputs,
          "#{inputs}_#{from_column}_seq_index",
          "#{inputs}_#{to_column}_seq_index",
          [to_column, "seq"]
        )

        rename_gin_index(repo, config, from_table, to_table)
      end

      :ok
    end

    # The other side of the rename, derived from the side we are on: the
    # override when the host gave one (same name both ways), otherwise the
    # prefix plus the other noun.
    @spec to_table(Config.t(), String.t()) :: String.t()
    defp to_table(%Config{} = config, from_table) do
      executions = Config.table(config, :executions)

      if from_table == executions,
        do: old_executions_table(config),
        else: executions
    end

    @spec rename_table(Ecto.Repo.t(), Config.t(), String.t(), String.t()) :: :ok
    defp rename_table(_repo, _config, same, same), do: :ok

    defp rename_table(repo, config, from, to) do
      run!(repo, "ALTER TABLE #{qualified(config, from)} RENAME TO #{quoted(to)}")
    end

    @spec rename_column(Ecto.Repo.t(), Config.t(), String.t(), String.t(), String.t()) :: :ok
    defp rename_column(repo, config, table, from, to) do
      if column_exists?(repo, config, table, from) do
        run!(
          repo,
          "ALTER TABLE #{qualified(config, table)} " <>
            "RENAME COLUMN #{quoted(from)} TO #{quoted(to)}"
        )
      end

      :ok
    end

    # Postgres renames an index; SQLite has no statement for it, so the
    # index is dropped and declared again under the new name. Either way no
    # row is read or written by this package.
    @spec rename_unique_index(
            Ecto.Repo.t(),
            Config.t(),
            String.t(),
            String.t(),
            String.t(),
            [String.t()]
          ) :: :ok
    defp rename_unique_index(repo, config, table, from, to, columns) do
      cond do
        not index_exists?(repo, config, from) ->
          :ok

        postgres?() ->
          run!(repo, "ALTER INDEX #{qualified(config, from)} RENAME TO #{quoted(to)}")

        true ->
          run!(repo, "DROP INDEX #{qualified(config, from)}")

          run!(
            repo,
            "CREATE UNIQUE INDEX #{quoted(to)} ON #{qualified(config, table)} " <>
              "(#{Enum.map_join(columns, ", ", &quoted/1)})"
          )
      end
    end

    # V03 creates the GIN index only on Postgres and derives its name from
    # the table, so it follows the table there and does not exist anywhere
    # else.
    @spec rename_gin_index(Ecto.Repo.t(), Config.t(), String.t(), String.t()) :: :ok
    defp rename_gin_index(repo, config, from_table, to_table) do
      from = "#{from_table}_metadata_gin_index"
      to = "#{to_table}_metadata_gin_index"

      if postgres?() and from != to and index_exists?(repo, config, from) do
        run!(repo, "ALTER INDEX #{qualified(config, from)} RENAME TO #{quoted(to)}")
      end

      :ok
    end

    @spec table_exists?(Ecto.Repo.t(), Config.t(), String.t()) :: boolean()
    defp table_exists?(repo, config, name) do
      if postgres?() do
        truthy?(repo, "SELECT to_regclass(#{literal(qualified(config, name))}) IS NOT NULL")
      else
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM sqlite_master " <>
            "WHERE type = 'table' AND name = #{literal(name)})"
        )
      end
    end

    @spec index_exists?(Ecto.Repo.t(), Config.t(), String.t()) :: boolean()
    defp index_exists?(repo, config, name) do
      if postgres?() do
        truthy?(repo, "SELECT to_regclass(#{literal(qualified(config, name))}) IS NOT NULL")
      else
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM sqlite_master " <>
            "WHERE type = 'index' AND name = #{literal(name)})"
        )
      end
    end

    @spec column_exists?(Ecto.Repo.t(), Config.t(), String.t(), String.t()) :: boolean()
    defp column_exists?(repo, config, table, column) do
      if postgres?() do
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
            "WHERE table_schema = #{schema_expression(config)} " <>
            "AND table_name = #{literal(table)} AND column_name = #{literal(column)})"
        )
      else
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM pragma_table_info(#{literal(table)}) " <>
            "WHERE name = #{literal(column)})"
        )
      end
    end

    @spec schema_expression(Config.t()) :: String.t()
    defp schema_expression(%Config{prefix: nil}), do: "current_schema()"
    defp schema_expression(%Config{prefix: prefix}), do: literal(prefix)

    @spec truthy?(Ecto.Repo.t(), String.t()) :: boolean()
    defp truthy?(repo, sql) do
      %{rows: [[answer]]} = repo.query!(sql, [])

      answer in [true, 1]
    end

    @spec run!(Ecto.Repo.t(), String.t()) :: :ok
    defp run!(repo, sql) do
      repo.query!(sql, [])

      :ok
    end

    @spec qualified(Config.t(), String.t()) :: String.t()
    defp qualified(%Config{prefix: nil}, name), do: quoted(name)
    defp qualified(%Config{prefix: prefix}, name), do: "#{quoted(prefix)}.#{quoted(name)}"

    @spec quoted(String.t()) :: String.t()
    defp quoted(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

    @spec literal(String.t()) :: String.t()
    defp literal(value), do: "'#{String.replace(value, "'", "''")}'"

    @spec postgres?() :: boolean()
    defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
  end
end
