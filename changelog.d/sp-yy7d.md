### Added

- `StatifierPersistence.Retention.prune/3` clears the position blob and the
  input log of every `:completed`, `:failed` or `:cancelled` execution whose
  `ended_at` is before a `DateTime` you pass, in batches, and keeps the
  execution row with its status, answer and `ended_at`. It takes no
  duration and has no default window.
- `StatifierPersistence.Storage.prune_executions/3` and
  `execution_pruning_supported?/1`, the one-batch facade beneath it, which
  answers `{:error, :execution_pruning_unsupported}` for an adapter that
  does not declare the capability.
- Two optional adapter callbacks, `supports_execution_pruning?/1` and
  `prune_executions/3`, implemented by the in-memory and Ecto adapters and
  checked by the conformance suite. An adapter of your own that exports
  neither stays conformant.
- `docs/retention.md`: which rows you may delete for a finished execution,
  and which you must not.
