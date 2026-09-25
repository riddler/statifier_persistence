### Fixed

- `StatifierPersistence.Executions.fail/4` called with `driver:` no longer
  draws a Dialyzer "no local return" warning in the calling module: an
  internal spec on the fail path typed the option list narrower than
  `fail/4`'s own `keyword()`.
