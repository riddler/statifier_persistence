### Added

- `StatifierPersistence.Run.Linkage.new/6` and `fan_out?/1`: a child's
  linkage can now carry its invocation's `child_count` and aggregation
  policy (`:all` or `:first_error`), which is what marks it as one of a
  fan-out's N rather than an ordinary durable subchart.
