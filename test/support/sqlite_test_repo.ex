defmodule StatifierPersistence.SqliteTestRepo do
  @moduledoc """
  A second test repo, on SQLite, for the one thing Postgres cannot show:
  what the versioned migration helper does on an adapter that is not
  Postgres (sp-11w).

  ADR-0005 decision 2 is untouched by this module. The harness for every
  storage, conformance and lock test is still a real Postgres server, and
  this repo backs no such test: it exists so V03's Postgres-conditional
  index and the Ecto adapter's Postgres-conditional metadata support are
  exercised by a real adapter rather than asserted about in a mock. The
  record's rejected-alternatives bullet argues against proving the *lock*
  contract on an embedded engine, which nothing here attempts.

  Its database is a file under `tmp/`, created and deleted by the test
  that starts the repo. Test-only support code, not part of the package's
  public API.
  """

  use Ecto.Repo,
    otp_app: :statifier_persistence,
    adapter: Ecto.Adapters.SQLite3

  defmodule Host do
    @moduledoc """
    The `use StatifierPersistence.Ecto` host on the SQLite repo, with its
    own table prefix so nothing it creates can collide with the Postgres
    fixtures' names.
    """
    use StatifierPersistence.Ecto,
      repo: StatifierPersistence.SqliteTestRepo,
      key: :uxid,
      table_prefix: "sq_"
  end
end
