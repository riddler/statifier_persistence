### Added

- `StatifierPersistence.Ecto.Migrations.expected_version/0` returns the
  newest migration version this package knows, for a host whose schema is
  hand-written DDL rather than a delegated migration and which therefore has
  to check for itself that its tables are current. There is no
  `assert_version!/1` to go with it: the package records no version marker in
  a repo's schema, so the comparison stays the host's - the function's docs
  say why.

### Documentation

- ADR-0010 takes a note answering whether a host needs the V05 input log
  table at all. An adapter that does not export the optional input-log
  callbacks never touches it - a host on one caps its migration at V04 in
  both directions rather than carrying an empty table - while a host storing
  through `StatifierPersistence.Storage.Ecto` needs it unconditionally,
  because that adapter declares input-log support without probing.
