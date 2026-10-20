# How to run the test suite

This guide shows you how to give this package's test suite the Postgres
server it needs, so that `mix test` and `mix quality` run green on your
machine.

The suite includes database-backed tests against a real Postgres server.
ADR-0005 (`docs/adr/0005-ecto-in-package-and-postgres-test-harness.md` in the
repository) rejects a skip tag for when one is absent, so `mix quality` and
`mix test` both need one reachable.

## Start the database

Start it once with:

    docker compose up -d db

which brings up `postgres:17` on `localhost:5432` with user/password
`postgres`.

## Use a server you already run

Override host, port, user, password, or database name with the `PGHOST`,
`PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` env vars (see
`config/test.exs` for the defaults) if a server is already running
elsewhere.

## Run the suite

    mix test

or the full quality gate, which runs the suite with coverage:

    mix quality
