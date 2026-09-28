### Added

- `StatifierPersistence.Testing.StorageConformance` gains a re-entrancy case for an adapter that exports `lock_execution/3`: a door called from inside its own execution's executor, under the default serialization strategy and so under the adapter's own lock, must answer `{:error, {:reentrant_step, execution_id}}` before it reaches the lock, and the outer step's position is the one stored. It carries `@tag :postgres` with the two lock cases, so a host running `Storage.Ecto` off Postgres now excludes five cases rather than four.
