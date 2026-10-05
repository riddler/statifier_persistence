import Config

# The default test database is per checkout, so two checkouts of this
# repository (the main one and a worktree, say) never run the suite against
# one database: the name carries the checkout directory's basename
# (sanitized, cut to 16 characters) and a hash of its full path, plus
# `_p` and MIX_TEST_PARTITION when `mix test --partitions` sets it. The
# longest name stays well under Postgres's 63-byte identifier limit.
# PGDATABASE, when set, wins over all of it (CI sets it).
checkout_root = Path.expand("..", __DIR__)

checkout_slug =
  checkout_root
  |> Path.basename()
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9]+/, "_")
  |> String.slice(0, 16)

checkout_hash =
  checkout_root
  |> :erlang.phash2(0x100000000)
  |> Integer.to_string(16)
  |> String.downcase()
  |> String.pad_leading(8, "0")

default_test_database =
  "statifier_persistence_test_#{checkout_slug}_#{checkout_hash}" <>
    case System.get_env("MIX_TEST_PARTITION", "") do
      "" -> ""
      partition -> "_p#{partition}"
    end

# ADR-0005: the test harness is a real Postgres server (docker compose
# locally, a service container in CI), reached through these PG* env vars so
# both environments configure the same repo without a mix.exs edit. Defaults
# match docker-compose.yml's `db` service.
config :statifier_persistence, StatifierPersistence.TestRepo,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: System.get_env("PGDATABASE", default_test_database),
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
