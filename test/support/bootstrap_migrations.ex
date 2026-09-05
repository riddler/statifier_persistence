defmodule StatifierPersistence.BootstrapMigrations do
  @moduledoc """
  The suite-wide DDL bootstrap: V01 tables for the fixture hosts the
  Ecto adapter tests run against, applied once by `test/test_helper.exs`
  through `Ecto.Migrator` (idempotent on `:already_up`) and left in
  place - the SQL sandbox rolls each test's rows back, so only the DDL
  persists between runs.

  Migrations 104 and 105 apply V02 (the runs `metadata` column) and V03
  (the runs `outcome_blob` column and the `metadata` GIN index) on their
  own with the helper's `from:`/`version:` options, because the migrations
  before each of them are already recorded as up in any database
  bootstrapped before that version existed.

  The `Kx*` hosts are not bootstrapped here: the live migration tests
  own their DDL end to end, up and down, and prove the helper itself.
  Test-only support code.
  """

  @migrations [
    {20_260_822_000_101, __MODULE__.DefaultTables},
    {20_260_822_000_102, __MODULE__.OverriddenTables},
    {20_260_829_000_103, __MODULE__.BlobTypedTables},
    {20_260_829_000_104, __MODULE__.RunMetadataColumns},
    {20_260_905_000_105, __MODULE__.RunOutcomeColumns}
  ]

  defmodule DefaultTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    def up, do: Migrations.up(for: EctoHosts.Default, version: 1)
    def down, do: Migrations.down(for: EctoHosts.Default)
  end

  defmodule OverriddenTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    def up, do: Migrations.up(for: EctoHosts.Overridden, version: 1)
    def down, do: Migrations.down(for: EctoHosts.Overridden)
  end

  defmodule BlobTypedTables do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    def up, do: Migrations.up(for: EctoHosts.BlobTyped, version: 1)
    def down, do: Migrations.down(for: EctoHosts.BlobTyped)
  end

  defmodule RunMetadataColumns do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    # V02 alone (`from: 2`), for the same reason a host already running V01
    # writes its second migration that way: the three migrations above ran
    # against databases created before V02 existed and are `:already_up`
    # there, so re-running them would not add the column.
    # `version: 2` pins the target as well as the start: without it this
    # migration would drift forward every time the package gains a
    # version, applying on a fresh database what migration 105 applies on
    # an existing one.
    def up do
      for host <- [EctoHosts.Default, EctoHosts.Overridden, EctoHosts.BlobTyped] do
        Migrations.up(for: host, from: 2, version: 2)
      end

      :ok
    end

    def down do
      for host <- [EctoHosts.Default, EctoHosts.Overridden, EctoHosts.BlobTyped] do
        Migrations.down(for: host, version: 2)
      end

      :ok
    end
  end

  defmodule RunOutcomeColumns do
    @moduledoc false
    use Ecto.Migration

    alias StatifierPersistence.Ecto.Migrations
    alias StatifierPersistence.EctoHosts

    # V03 alone, for the reason migration 104 applies V02 alone.
    def up do
      for host <- [EctoHosts.Default, EctoHosts.Overridden, EctoHosts.BlobTyped] do
        Migrations.up(for: host, from: 3, version: 3)
      end

      :ok
    end

    def down do
      for host <- [EctoHosts.Default, EctoHosts.Overridden, EctoHosts.BlobTyped] do
        Migrations.down(for: host, version: 3)
      end

      :ok
    end
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
