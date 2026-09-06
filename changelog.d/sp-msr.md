### Changed

- The conformance suite tags its four Postgres-only cases `@tag :postgres` -
  the two `lock_run/3` cases and the two metadata-listing cases - so a host
  running `Storage.Ecto` on another Ecto backend runs it green with
  `mix test --exclude postgres` instead of forking the suite.

### Added

- `docs/non-postgres-backends.md`: the supported way to run the Ecto adapter
  on a backend that is not Postgres - decline `lock_run/3` with your own
  `serialization:` strategy, what declining costs, and how to verify it.
