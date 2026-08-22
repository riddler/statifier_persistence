# sp-4an.3.1

## Added

- `StatifierPersistence.Storage.Ecto`: the Postgres storage adapter over
  the schemas a host generates with `use StatifierPersistence.Ecto`
  (`Storage.new(Storage.Ecto, persistence: MyApp.Persistence)`). Passes
  the same conformance suite as the in-memory reference adapter; engine
  identities stored verbatim; `:run_exists` enforced atomically by the
  unique index.
- `Storage.Ecto.isolate/1`: with `sandbox: true`, wraps each test in its
  own `Ecto.Adapters.SQL.Sandbox` checkout - the hook host test suites
  (and this package's conformance suite) isolate through.
- `Storage.Ecto.lock_run/3`: per-run mutual exclusion as a
  transaction-scoped `pg_advisory_xact_lock` plus a `SELECT ... FOR
  UPDATE` row lock (ADR-0004 as amended), consumed by
  `Serialization.AdapterLock`.
