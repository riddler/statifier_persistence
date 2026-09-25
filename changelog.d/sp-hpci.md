### Changed

- **Breaking** for a host that calls `StatifierPersistence.Executions.migrate/4` on a durable child, or matches `t:StatifierPersistence.Executions.migrate_error/0` exhaustively: `migrate/4` now refuses an execution that carries a linkage with `{:error, {:linked, execution}}` and writes nothing, under either `on_failure:` value. Move a child with `StatifierPersistence.Executions.migrate_tree/4`, the child as the root, and add a clause for `{:linked, execution}`, or a catch-all, to every `case` over `migrate/4`'s refusals.
