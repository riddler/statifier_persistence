### Added

- Adds an optional per-run input log to the storage-adapter behaviour
  (`supports_input_log?/1`, `append_input/3`, `list_inputs/2`): an adapter
  that exports them records every input a run's interpreter saw - the
  verbatim `%Statifier.Event{}`, the public door it entered by, and a
  dense zero-based ordinal - which is what an offline replay of a durably
  stepped run needs (ADR-0010).
- Adds `StatifierPersistence.Runs.inputs/2` and
  `StatifierPersistence.Storage.input_log_supported?/1`,
  `append_input/4` and `list_inputs/2` for reading and writing that log.
- Adds migration V05, the input log table, on Postgres and SQLite alike;
  `StatifierPersistence.Storage.Ecto` implements all three callbacks and
  takes an `input_log_cap:` option that bounds a run's log and closes it
  with a marker entry rather than truncating it silently. The default is
  `:infinity`.
- `:blob_type` now reaches the new `input_blob` column. An event's `data`
  is host payload, so turning the log on is a data-retention decision:
  an adapter that does not export `supports_input_log?/1` keeps no log
  and behaves exactly as it did before.
