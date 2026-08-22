# sp-02x

## Added

- `use StatifierPersistence.Ecto`: compile-time configuration on the host's
  module (`repo:`, `key:`, `table_prefix:`, `tables:`, `prefix:`) that
  defines `Chart`, `Position`, and `Run` schema modules and exposes the
  resolved config via `__statifier_persistence__/1`. Requires the optional
  `ecto_sql` dependency.
- `StatifierPersistence.Ecto.KeyGenerator`: the behaviour a surrogate-key
  scheme implements, with `:uxid` (default), `:uuid` (UUIDv7), `:bigserial`,
  and `{module, opts}` resolved through `resolve/1`.
- `StatifierPersistence.Ecto.Migrations`: the versioned migrations helper
  (`up/1`, `down/1`, taking `for: HostModule` or the same literal options
  `use` takes) that creates the `charts`/`positions`/`runs` tables from the
  same resolved config the schemas use.

## Changed

- `uxid` is now a required dependency (the default key scheme works out of
  the box); `ecto_sql` is an optional dependency and the package compiles
  without it.
