### Fixed

- V03 of the Ecto migration helper is adapter-aware: the `metadata` GIN
  `jsonb_path_ops` index is created (and dropped) only when the
  migration's repo runs on `Ecto.Adapters.Postgres`. On any other adapter
  it is skipped and the migration runs to completion, so a host on
  another backend can apply the package DDL at all - in 0.7.0 the index
  raised, the whole migration rolled back, and the `outcome_blob` column
  went with it. The column itself is still created on every adapter, and
  `StatifierPersistence.Storage.Ecto.supports_run_outcome?/1` is still
  true everywhere.
- `StatifierPersistence.Storage.Ecto.supports_metadata?/1` now answers
  `false` off Postgres, because both metadata queries the adapter issues
  are `jsonb` containment SQL. `StatifierPersistence.Storage`'s
  `child_listing_supported?/1` and `run_states_supported?/1` consult it,
  so a durable subchart or a fan-out over such a store is refused at open
  (`:child_listing_unsupported`) rather than started and left with
  children nothing could settle. Behavior on Postgres is unchanged.
