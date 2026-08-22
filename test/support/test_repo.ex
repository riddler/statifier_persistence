defmodule StatifierPersistence.TestRepo do
  @moduledoc """
  The Ecto repo backing this package's own test suite.

  ADR-0005: database-backed tests run against a real Postgres server rather
  than a fake or an embedded stand-in, isolated per test through
  `Ecto.Adapters.SQL.Sandbox`. This module is test-only support code, not
  part of the package's public API - a host configures its own repo through
  `use StatifierPersistence.Ecto, repo: MyApp.Repo` (ADR-0002 decision 3).
  """

  use Ecto.Repo,
    otp_app: :statifier_persistence,
    adapter: Ecto.Adapters.Postgres
end
