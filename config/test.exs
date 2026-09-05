import Config

# ADR-0005: the test harness is a real Postgres server (docker compose
# locally, a service container in CI), reached through these PG* env vars so
# both environments configure the same repo without a mix.exs edit. Defaults
# match docker-compose.yml's `db` service.
config :statifier_persistence, StatifierPersistence.TestRepo,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: System.get_env("PGDATABASE", "statifier_persistence_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# sp-11w: the second repo, on SQLite, that
# `test/statifier_persistence/ecto/sqlite_migrations_test.exs` starts for
# itself. Its database is a file the test creates and deletes; nothing
# else in the suite touches this repo, and ADR-0005 decision 2's Postgres
# harness above is unchanged.
config :statifier_persistence, StatifierPersistence.SqliteTestRepo,
  database: System.get_env("SQLITE_TEST_DATABASE", "tmp/sp_11w_sqlite_test.db"),
  pool_size: 1
