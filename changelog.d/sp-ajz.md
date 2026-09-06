### Added

- V04 of the Ecto DDL rebuilds V03's `metadata` GIN index with `CREATE INDEX
  CONCURRENTLY`, so a host with a large runs table gets the index without the
  `SHARE` lock a plain build holds. Give it a migration of its own carrying
  `@disable_ddl_transaction true` and `@disable_migration_lock true` - Ecto
  reads those from your module, not from the helper - and call
  `StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence, from: 4)`.
  Called from an ordinary transactional migration it leaves V03's index in
  place instead of raising, warning when the runs table already holds rows.
  It is a no-op off `Ecto.Adapters.Postgres`, where V03 creates no index.
