### Added

- `StatifierPersistence.Driver.start_child_at/6`: the public
  start-with-index door a scheduler drives a Tier A fan-out through.
  Starts child `i` of `N` for a parent's `<invoke>`, records the count and
  the aggregation policy (`:all` or `:first_error`) on the child's
  linkage, and is idempotent on the derived child run id, so a
  re-delivered start adopts rather than duplicating. Refuses at open on a
  store that could not settle the invocation afterwards.
- `StatifierPersistence.Run.Linkage.new/6`
 and `fan_out?/1`: a child's
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
- `StatifierPersistence.Driver` takes a `child_canceller:` option: how a
  `:first_error` settlement asks the scheduler to cancel the start jobs of
  a fan-out's not-yet-started children, which have no run record for the
  cascade to reach.
- A fan-out child's completion now settles instead of answering its
  parent's door: its answer is stored on its own run record, and only the
  settlement that finds all N indices terminal assembles the dense,
  index-ordered list and answers the invocation once.
  `StatifierPersistence.Driver.answer_parent/3` routes a fan-out child the
  same way and returns `:ok` for it. A child with no `child_count` on its
  linkage - every child created before this release - is unaffected.
