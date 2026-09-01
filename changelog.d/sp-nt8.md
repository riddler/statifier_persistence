### Added

- Durable subcharts (ADR-0008): a `<invoke>` whose `:dispatch` fun answers
  `{:start_child, invoke, {:invoke, invoke}}` now starts the subchart as an
  ordinary durable run instead of being refused, and the parent rests holding
  no process for as long as the child takes.
- `StatifierPersistence.Run.Linkage` records a child's parent run id,
  invocation id, and a mandatory pin of the child's chart identity under a
  reserved key in the child's run `metadata`.
- `StatifierPersistence.Runs.create/4` takes `linkage:`, and raises
  `ArgumentError` when a host's own `metadata:` writes into the reserved key.
- `StatifierPersistence.Driver.new/3` takes `chart_resolver:`, which lets a
  finished child answer its parent through the existing `done_invocation/5`
  and `failed_invocation/5` doors.
- `StatifierPersistence.Runs.cancel/3` and `cascade_cancel/3` cancel a
  parent's child subtree when it leaves the invoking state, retaining every
  record and position.
- Storage adapters may export the optional `list_runs_by_metadata/2`, reached
  through `StatifierPersistence.Storage.list_runs_by_metadata/2` and
  `child_listing_supported?/1`; a store whose adapter does not export it
  refuses a durable subchart before any write.
- `StatifierPersistence.Storage.InMemory` implements `list_runs_by_metadata/2`,
  which `StatifierPersistence.Storage.Ecto` already supported.

### Changed

- `StatifierPersistence.Storage.Adapter.run_status/0` gains a fourth terminal
  value, `:cancelled`. An adapter that encodes statuses by an exhaustive match
  must add a clause for it, or cancelled runs will fail to persist.
- `StatifierPersistence.Run` gains `donedata`, set only on the step that
  completes a run and `nil` everywhere else.
