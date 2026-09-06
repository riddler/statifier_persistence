### Added

- `StatifierPersistence.Ecto.Migrations.down/1` takes `from:`, the version it
  starts rolling back from (default: the newest this package knows), so a
  migration capped with `up(version: 2)` caps its rollback with
  `down(from: 2)`.

### Fixed

- `mix ecto.rollback --all` no longer fails for a host that caps one
  migration and takes a later version in another: without a ceiling every
  `down/1` started at the newest version, so the capped migration rolled the
  later one's versions back a second time and failed on DDL that was already
  gone. Cap the rollback with `from:` as above.
