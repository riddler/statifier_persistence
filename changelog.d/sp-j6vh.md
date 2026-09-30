### Changed

- `StatifierPersistence.Storage.Ecto` keys its per-chart advisory lock on Postgres by the store (the chart table under its prefix) as well as the content hash, so two stores in one database no longer wait on each other for a hash they share; every caller of one store still shares the lock, the first key is unchanged, and a host that held its own advisory locks against the old key sees no overlap it did not see before.
