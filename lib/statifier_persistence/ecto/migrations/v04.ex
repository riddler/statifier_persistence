if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V04 do
    @moduledoc """
    V04 of the package DDL: rebuilds V03's `metadata` GIN index with
    `CREATE INDEX CONCURRENTLY`.

    V03 creates that index with a plain `CREATE INDEX`, which takes a
    `SHARE` lock on the runs table for the whole build and blocks every
    `INSERT`, `UPDATE` and `DELETE` against it until the build finishes.
    For a host stepping runs durably that is every step of every run. On
    a small or idle table the build is imperceptible; on a large one it
    is an outage, and the README's answer used to be a hand-written
    migration the host maintained itself (sp-ajz).

    This version ships that answer instead. It drops the index V03 built
    and creates the same index again - same name, same expression, same
    `jsonb_path_ops` opclass - with `concurrently: true` on both
    statements, so neither blocks writes.

    ## The host's migration module is what disables the transaction

    `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block,
    and `@disable_ddl_transaction` / `@disable_migration_lock` are read
    by `Ecto.Migrator` from the module it is *running* - the host's own
    migration - not from this module. A package migration module cannot
    turn its caller's transaction off. So a host that wants the
    concurrent build writes:

        defmodule MyApp.Repo.Migrations.RebuildStatifierPersistenceMetadataIndex do
          use Ecto.Migration

          @disable_ddl_transaction true
          @disable_migration_lock true

          def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 4)
          def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 4)
        end

    and `up/1` **skips** when it finds itself inside a transaction after
    all. Skipping rather than raising is deliberate: the end state of a
    skipped V04 is the index V03 already built, which is correct and
    complete, differing only in how it was built. Raising would break the
    one-call recipe (`up(for: MyApp.Persistence)`) that every fresh
    database and every test harness uses, to no benefit - on an empty
    runs table a plain build costs nothing.

    The skip warns through `Logger.warning/1` **only when the runs table
    already holds rows**, which is exactly the case where the plain build
    blocked writes and the host has something to do about it. A fresh
    database migrates in silence.

    ## Rolling back

    `down/1` does nothing, on every adapter, and that is the whole
    rollback. What V04 leaves behind is not a new object: it is V03's
    index, under V03's name, with V03's definition, and V03's `down/1`
    is what drops it. Rebuilding it plainly on the way down would take
    exactly the `SHARE` lock this version exists to avoid, in order to
    reach a state no reader can tell apart from the one it started in.

    ## Failure part-way through

    A non-transactional migration has no rollback, so an interrupted
    `up/1` can leave the runs table with no `metadata` index or with an
    invalid one. Re-running the migration is the repair: the drop is
    `drop_if_exists`, so it clears either leftover, and the create then
    builds the index once more. Nothing in the package's DDL depends on
    the index existing; what depends on it is the cost of the two
    containment queries V03's moduledoc names.

    ## Adapters other than Postgres

    `up/1` and `down/1` are both no-ops off `Ecto.Adapters.Postgres`,
    under the same exact-match adapter check V03 uses and for the same
    reason: `GIN` and `jsonb_path_ops` are Postgres spellings, so on any
    other adapter there is no index to rebuild - V03 skipped creating one
    (sp-11w), and `docs/non-postgres-backends.md` describes what that
    costs such a host. The check runs before the transaction check, so a
    SQLite host needs neither attribute.
    """

    use Ecto.Migration

    require Logger

    alias StatifierPersistence.Ecto.Config

    @doc """
    Rebuilds the `metadata` GIN index concurrently per `config`.

    A no-op off Postgres, and a no-op with a warning when the host's
    migration module has not disabled the DDL transaction - see the
    moduledoc.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      cond do
        not postgres?() ->
          :ok

        repo().in_transaction?() ->
          warn_skipped(config)

        true ->
          rebuild_concurrently(config)
      end
    end

    @doc "Leaves V03's index in place - see the moduledoc's rollback section."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = _config), do: :ok

    # Only a runs table that already holds rows had anything to lose to
    # V03's plain build, and that is the only case worth a warning: a fresh
    # database - every new deployment, every test harness - reaches here
    # through the one-call recipe with an empty table, where the plain
    # build cost nothing and there is nothing for the host to do about it.
    # `LIMIT 1` under `EXISTS` stops at the first row, so the check is not
    # a count and does not care how large the table is.
    #
    # The check goes through `execute/1`'s function form rather than
    # running here, because `Ecto.Migration.Runner` queues a migration's
    # commands and runs them at the end: asking the runs table anything
    # from the body of `up/1` reaches it before V01 has created it, on
    # every fresh database. A queued function runs in order, after the
    # DDL ahead of it.
    @spec warn_skipped(Config.t()) :: :ok
    defp warn_skipped(%Config{} = config) do
      repo = repo()
      present_sql = "SELECT EXISTS (SELECT 1 FROM #{qualified_runs(config)} LIMIT 1)"

      execute(fn ->
        %{rows: [[present?]]} = repo.query!(present_sql, [])

        if present? do
          Logger.warning(
            "statifier_persistence V04 skipped the concurrent rebuild of the " <>
              "metadata GIN index: this migration is running inside a DDL " <>
              "transaction, and CREATE INDEX CONCURRENTLY cannot. The index " <>
              "V03 built is in place and correct, but it was built with a " <>
              "plain CREATE INDEX, which held a SHARE lock on the runs table " <>
              "for the whole build. To build it without blocking writes, put " <>
              "@disable_ddl_transaction true and @disable_migration_lock true " <>
              "on the host migration module that calls this helper."
          )
        end

        :ok
      end)

      :ok
    end

    @spec qualified_runs(Config.t()) :: String.t()
    defp qualified_runs(%Config{prefix: nil} = config) do
      ~s("#{Config.table(config, :runs)}")
    end

    defp qualified_runs(%Config{} = config) do
      ~s("#{config.prefix}"."#{Config.table(config, :runs)}")
    end

    @spec rebuild_concurrently(Config.t()) :: :ok
    defp rebuild_concurrently(%Config{} = config) do
      runs = Config.table(config, :runs)

      drop_if_exists(
        index(runs, ["metadata"],
          name: index_name(runs),
          prefix: config.prefix,
          concurrently: true
        )
      )

      create(
        index(runs, ["metadata jsonb_path_ops"],
          using: "GIN",
          name: index_name(runs),
          prefix: config.prefix,
          concurrently: true
        )
      )

      :ok
    end

    # The same explicit name V03 uses, for the same reason: the index this
    # version drops has to be the one V03 created, and the one it creates
    # has to be the one V03's `down/1` drops.
    @spec index_name(String.t()) :: atom()
    defp index_name(runs), do: :"#{runs}_metadata_gin_index"

    @spec postgres?() :: boolean()
    defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
  end
end
