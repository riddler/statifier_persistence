### Fixed

- `StatifierPersistence.Testing.StorageConformance` retires only chart hashes derived from the using module's name, so two or more modules running it asynchronously against one Postgres database no longer deadlock (`40P01`) in the tombstone-check case or in the cases that retire a hash after a create's or a migration's first check.
