defmodule StatifierPersistence.BootstrapMigrations do
  @moduledoc """
  The suite-wide DDL bootstrap: V01 tables for the fixture hosts the
  Ecto adapter tests run against, applied once by `test/test_helper.exs`
  through `Ecto.Migrator` (idempotent on `:already_up`) and left in
  place - the SQL sandbox rolls each test's rows back, so only the DDL
  persists between runs.

  The `Kx*` hosts are not bootstrapped here: the live migration tests
  own their DDL end to end, up and down, and prove the helper itself.
  Test-only support code.
  """

  @migrations [
    {20_260_822_000_101, __MODULE__.DefaultTables},
    {20_260_822_000_102, __MODULE__.OverriddenTables}
  ]

  defmodule DefaultTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    def up, do: Migrations.up(for: EctoHosts.Default)
    def down, do: Migrations.down(for: EctoHosts.Default)
  end

  defmodule OverriddenTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    def up, do: Migrations.up(for: EctoHosts.Overridden)
    def down, do: Migrations.down(for: EctoHosts.Overridden)
  end

  @doc "Applies every bootstrap migration, tolerating `:already_up`."
  @spec up(module()) :: :ok
  def up(repo) do
    for {version, module} <- @migrations do
      case Ecto.Migrator.up(repo, version, module, log: false) do
        :ok -> :ok
        :already_up -> :ok
      end
    end

    :ok
  end
end
