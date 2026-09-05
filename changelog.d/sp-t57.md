### Added

- `StatifierPersistence.Run.Linkage.new/6` and `fan_out?/1`: a child's
  linkage can now carry its invocation's `child_count` and aggregation
  policy (`:all` or `:first_error`), which is what marks it as one of a
  fan-out's N rather than an ordinary durable subchart.

### Changed

- The storage-adapter `run_record` gains a nullable `outcome_blob`: a
  run's own answer, written once when it reaches a terminal status
  through `StatifierPersistence.Storage.update_run_status/4`'s new
  `outcome_blob:` option. `update_run/2` carries a stored payload forward
  when the record it is given carries none, so an ordinary step never
  erases one. Adapters gain two optional callbacks alongside it -
  `supports_run_outcome?/1` and `list_run_states_by_metadata/2`, the
  indexed status projection - and an adapter that exports neither is
  conformant unchanged.
- The Ecto adapter's V03 migration adds the `outcome_blob` column and a
  GIN `jsonb_path_ops` index on `metadata`. A host already on V02 picks
  it up with `StatifierPersistence.Ecto.Migrations.up(for: MyApp, from: 3)`.
