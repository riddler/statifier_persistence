### Added

- `StatifierPersistence.Testing.StorageConformance` gains two cases for an adapter that exports `retire_chart/3`: a create, and a migration, whose hash is retired after their first check and before their write must answer `{:error, {:chart_retired, info}}` and write nothing. They run under a serialization strategy of the suite's own, need no `lock_execution/3` and carry no tag.

### Changed

- A create, migration or tree migration that races a retirement of its chart no longer leaves an execution on the retired chart on the Ecto adapter over Postgres or on the in-memory adapter: either the write answers `{:error, {:chart_retired, info}}` or the retirement answers `{:error, {:pinned, counts}}`. A tree refused by its re-read of the chart carries that arm per node inside `{:tree_refused, refusals}`; on the in-memory adapter a tree that loses at its write answers the bare `{:error, {:chart_retired, info}}`, and a create that loses at its insert is refused after its executor has run the create's effects. On the Ecto adapter over Postgres the write reads the chart's tombstone under a per-chart shared advisory lock it holds until it commits, and a retirement takes that lock exclusively first; on another backend, and under a host `serialization:` strategy, the window is narrowed, not closed. The winning interleaving answers what it answered before.
