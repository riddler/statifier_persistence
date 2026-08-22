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

Ecto.Adapters.SQL.Sandbox.mode(StatifierPersistence.TestRepo, :manual)

ExUnit.start()
