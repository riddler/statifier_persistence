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

    `version:` selects the target version. `up/1` migrates from V01 through
    the target (default: the newest this package knows); `down/1` rolls back
    from the newest through the target (default: V01, i.e. everything).

    `from:` selects where `up/1` starts (default: V01). It is what a host
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

    When `prefix:` names a Postgres schema, `up/1` creates the schema if it
    does not exist; `down/1` leaves the schema in place (dropping a schema
    the host may share is not this package's call).
    """

    alias StatifierPersistence.Ecto.Config

    @initial_version 1
    @current_version 2

    @migrations %{
      1 => StatifierPersistence.Ecto.Migrations.V01,
      2 => StatifierPersistence.Ecto.Migrations.V02
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
    Rolls the tables back from the newest version through `version:`
    (default: V01, i.e. everything). Takes the same options as `up/1`.
    """
    @spec down(keyword()) :: :ok
    def down(opts) when is_list(opts) do
      {config, target} = parse!(opts, @initial_version)

      Enum.each(@current_version..target//-1, fn version ->
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
