defmodule StatifierPersistence.EctoHosts do
  @moduledoc """
  Fixture host modules for `use StatifierPersistence.Ecto` tests.

  Three hosts spanning the option surface: the zero-config default, a
  host overriding every knob, and a host on database-assigned keys.
  Test-only support code, not part of the package's public API.

  The `Kx*` hosts back the live migration tests: one per key scheme, each
  with a distinct `kx_` table prefix so their DDL coexists in one database
  and is dropped wholesale after the suite.
  """

  defmodule Default do
    @moduledoc false
    use StatifierPersistence.Ecto, repo: StatifierPersistence.TestRepo
  end

  defmodule Overridden do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      key: :uuid,
      table_prefix: "wf_",
      tables: %{runs: "workflow_runs"},
      prefix: "workflows"
  end

  defmodule Bigserial do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      key: :bigserial
  end

  defmodule KxUxid do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      key: :uxid,
      table_prefix: "kx_uxid_"
  end

  defmodule KxUuid do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      key: :uuid,
      table_prefix: "kx_uuid_"
  end

  defmodule KxBigserial do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      key: :bigserial,
      table_prefix: "kx_big_"
  end
end
