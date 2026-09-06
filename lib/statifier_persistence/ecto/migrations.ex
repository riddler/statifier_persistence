if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations do
    @moduledoc """
    Versioned migrations for this package's tables, in the `Oban.Migration`
    mold: the host writes one ordinary migration that delegates here, and
    later package versions ship higher-numbered migration modules the same
    call picks up.

    The supported spelling reads the host's compiled configuration, so the
    DDL cannot drift from the generated schemas (ADR-0002 decision 3):

        defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
          use Ecto.Migration

          def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence)
          def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence)
        end

    Alternatively, `up/1` and `down/1` accept the same literal options
    `use StatifierPersistence.Ecto` takes (`:repo`, `:key`, `:table_prefix`,
    `:tables`, `:prefix`), funneled through the same
    `StatifierPersistence.Ecto.Config.new/1` - one resolver, both doors.
    The two spellings cannot be mixed in one call.

    `from:` selects where a call starts and `version:` where it ends, in
    both directions: `up/1` migrates from `from:` (default: V01) up through
    `version:` (default: the newest this package knows), and `down/1` rolls
    back from `from:` (default: the newest) down through `version:`
    (default: V01, i.e. everything).

    `from:` is what a host
    already running an older version writes its *next* migration with: a
    host that ran the migration above when this package shipped only V01
    picks up V02 with a second ordinary migration,

        defmodule MyApp.Repo.Migrations.AddStatifierPersistenceRunMetadata do
          use Ecto.Migration

          def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 2)
          def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 2)
        end

    rather than re-running V01's `CREATE TABLE` against tables that already
    exist. A host migrating a fresh database with the first spelling gets
    every version in one call and needs no second migration at all.

    Each migration's two calls cover the same span, `up/1` upwards and
    `down/1` downwards, and a *capped* migration needs both bounds spelled
    out. A host that caps its first migration at `version: 2` - so that a
    fresh clone and an already-migrated database take the same steps in the
    same order - caps the rollback to match with `from: 2`:

        defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
          use Ecto.Migration

          def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, version: 2)
          def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, from: 2)
        end

    Without that ceiling `down/1` starts at the newest version this package
    knows however far up the migration beside it went, so
    `mix ecto.rollback --all` rolls V03 back twice - once from the later
    migration and once from this one - and the second call fails on a
    column that is already gone.

    V04 is the one version whose full effect depends on how the host's
    own migration module is written. It rebuilds V03's `metadata` GIN
    index with `CREATE INDEX CONCURRENTLY`, which cannot run inside a
    transaction, and `@disable_ddl_transaction` / `@disable_migration_lock`
    are read from the module `Ecto.Migrator` runs - the host's - not from
    a module it delegates to. A host that wants the concurrent build
    therefore gives V04 a migration of its own:

        defmodule MyApp.Repo.Migrations.RebuildStatifierPersistenceMetadataIndex do
          use Ecto.Migration

          @disable_ddl_transaction true
          @disable_migration_lock true

          def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 4)
          def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence, version: 4)
        end

    Inside a transaction V04 skips the rebuild and leaves V03's index in
    place, which is the same index under the same name - so the one-call
    recipe above stays correct on a fresh database, where a plain build
    on an empty runs table costs nothing. It warns only when that table
    already holds rows. `StatifierPersistence.Ecto.Migrations.V04`
    records the whole of it.

    V05 needs no recipe of its own: it creates ADR-0010's input log table
    and its unique `(run_id, seq)` index, on every backend, inside an
    ordinary transaction. A host already running V04 picks it up with
    `up(for: MyApp.Persistence, from: 5)`.

    When `prefix:` names a Postgres schema, `up/1` creates the schema if it
    does not exist; `down/1` leaves the schema in place (dropping a schema
    the host may share is not this package's call).
    """

    alias StatifierPersistence.Ecto.Config

    @initial_version 1
    @current_version 5

    @migrations %{
      1 => StatifierPersistence.Ecto.Migrations.V01,
      2 => StatifierPersistence.Ecto.Migrations.V02,
      3 => StatifierPersistence.Ecto.Migrations.V03,
      4 => StatifierPersistence.Ecto.Migrations.V04,
      5 => StatifierPersistence.Ecto.Migrations.V05
    }

    @doc """
    Migrates the tables from `from:` (default: V01) up through `version:`
    (default: the newest).

    Takes `for: HostModule` or the literal options `use` takes - see the
    moduledoc.
    """
    @spec up(keyword()) :: :ok
    def up(opts) when is_list(opts) do
      {from, opts} = Keyword.pop(opts, :from, @initial_version)
      validate_version!(from, "from")
      {config, target} = parse!(opts, @current_version)

      if from > target do
        raise ArgumentError,
              "from: #{from} is above version: #{target}; up/1 does not roll back"
      end

      Enum.each(from..target, fn version ->
        Map.fetch!(@migrations, version).up(config)
      end)
    end

    @doc """
    Rolls the tables back from `from:` (default: the newest version this
    package knows) down through `version:` (default: V01, i.e. everything).

    A migration whose `up/1` is capped at `version: N` caps its `down/1`
    with `from: N`, so the rollback stops at the cap instead of reaching
    versions a later migration has already rolled back - see the moduledoc.

    Takes the same options as `up/1`.
    """
    @spec down(keyword()) :: :ok
    def down(opts) when is_list(opts) do
      {from, opts} = Keyword.pop(opts, :from, @current_version)
      validate_version!(from, "from")
      {config, target} = parse!(opts, @initial_version)

      if from < target do
        raise ArgumentError,
              "from: #{from} is below version: #{target}; down/1 does not migrate up"
      end

      Enum.each(from..target//-1, fn version ->
        Map.fetch!(@migrations, version).down(config)
      end)
    end

    defp parse!(opts, default_version) do
      {version, opts} = Keyword.pop(opts, :version, default_version)
      validate_version!(version, "version")

      {config!(opts), version}
    end

    defp validate_version!(version, name) do
      if not (is_integer(version) and version in @initial_version..@current_version) do
        raise ArgumentError,
              "unknown migration #{name} #{inspect(version)}; " <>
                "this package knows versions #{@initial_version} " <>
                "through #{@current_version}"
      end

      :ok
    end

    defp config!(opts) do
      case Keyword.pop(opts, :for) do
        {nil, opts} ->
          Config.new(opts)

        {host, []} when is_atom(host) ->
          host_config!(host)

        {_host, rest} ->
          raise ArgumentError,
                "for: cannot be combined with literal options; " <>
                  "got #{inspect(Keyword.keys(rest))} alongside it"
      end
    end

    defp host_config!(host) do
      if Code.ensure_loaded?(host) and function_exported?(host, :__statifier_persistence__, 1) do
        host.__statifier_persistence__(:config)
      else
        raise ArgumentError,
              "#{inspect(host)} does not use StatifierPersistence.Ecto, " <>
                "so it carries no configuration to migrate for"
      end
    end
  end
end
