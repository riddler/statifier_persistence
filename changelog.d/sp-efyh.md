### Added

- `StatifierPersistence.Retention.prune/3` takes `single_batch: true` to prune one batch and answer its counts plus `more?`, so a host can hold one short transaction of its own per batch; its docs now say that a call inside a caller's transaction prunes every batch in that one transaction.
