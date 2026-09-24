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

# The sandbox stays :manual except inside the modules that must run live,
# outside the sandbox: the tests that run their own DDL (migrations_test,
# v06_rename_test, leading_columns_test) and the tests that need a second
# connection to meet a real lock or a caller's real transaction (the live
# lock, held lease, caller transaction, retire race and live fan-out
# tests). Each switches the repo to
# :auto in its setup or setup_all and restores :manual on exit.
#
# The mode belongs to the one shared repo, not to the module that set it,
# so what keeps :auto inside those modules is ExUnit's ordering: every
# async module runs first, and the synchronous modules run only after all
# of them have finished, one at a time. A module that leaves :manual is
# therefore never `async: true`; SandboxModeTest reads the suite's source
# and fails on one that is.
Ecto.Adapters.SQL.Sandbox.mode(StatifierPersistence.TestRepo, :manual)

ExUnit.start()
