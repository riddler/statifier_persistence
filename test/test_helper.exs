# ADR-0005: database-backed tests are ordinary tests in the ordinary suite,
# against a real Postgres server - no tag skips them when the server is
# absent. Create the test database if it does not exist yet, start the
# repo, and put the SQL sandbox in :manual mode so each test checks out its
# own connection.
{:ok, _} = Application.ensure_all_started(:postgrex)

case Ecto.Adapters.Postgres.storage_up(StatifierPersistence.TestRepo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _pid} = StatifierPersistence.TestRepo.start_link()

# The Ecto adapter tests (conformance and unit) run against the Default
# and Overridden fixture hosts' tables; create them once for the whole
# suite, idempotently. Only DDL persists - the sandbox rolls rows back.
:ok = StatifierPersistence.BootstrapMigrations.up(StatifierPersistence.TestRepo)

# The sandbox stays :manual for everything except the live migration tests
# (migrations_test.exs, async: false), which manage their own DDL and
# inserts: they switch the repo to :auto for the duration of their
# setup_all/on_exit work and restore :manual afterward.
Ecto.Adapters.SQL.Sandbox.mode(StatifierPersistence.TestRepo, :manual)

ExUnit.start()
