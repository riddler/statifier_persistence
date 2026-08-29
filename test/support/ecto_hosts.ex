defmodule StatifierPersistence.EctoHosts do
  @moduledoc """
  Fixture host modules for `use StatifierPersistence.Ecto` tests.

  Hosts spanning the option surface: the zero-config default, a host
  overriding every knob, a host on database-assigned keys, and
  `BlobTyped`, which puts the generic reversible transform
  (`StatifierPersistence.Test.ReversibleBlobType`) on `:blob_type`.
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

  defmodule BlobTyped do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      table_prefix: "blobtype_",
      blob_type: StatifierPersistence.Test.ReversibleBlobType
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
