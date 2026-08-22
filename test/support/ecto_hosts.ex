defmodule StatifierPersistence.EctoHosts do
  @moduledoc """
  Fixture host modules for `use StatifierPersistence.Ecto` tests.

  Three hosts spanning the option surface: the zero-config default, a
  host overriding every knob, and a host on database-assigned keys.
  Test-only support code, not part of the package's public API.
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
end
