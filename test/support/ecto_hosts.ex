defmodule StatifierPersistence.EctoHosts do
  @moduledoc """
  Fixture host modules for `use StatifierPersistence.Ecto` tests.

  Hosts spanning the option surface: the zero-config default, a host
  overriding every knob, a host on database-assigned keys, and
  `BlobTyped`, which puts the generic reversible transform
  (`StatifierPersistence.Test.ReversibleBlobType`) on `:blob_type`, and
  `Scoped`, which places a host-owned `tenant_id` with `:leading_columns`.
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
      # Deliberately still the name this host chose before 0.12.0: ADR-0011
      # decision 3 renames the package's default table, not a name a host
      # gave itself, and V06 renames the columns and indexes under whatever
      # name it finds. This fixture is what proves that branch.
      tables: %{executions: "workflow_runs"},
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

  # A partitioned host: one leading column the host owns, in a Postgres
  # schema of its own, so a scoped prune is proven through the queries
  # that name the table and carry the schema prefix themselves.
  defmodule Scoped do
    @moduledoc false
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.TestRepo,
      prefix: "scoped",
      leading_columns: [tenant_id: {:text, null: true}]
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
