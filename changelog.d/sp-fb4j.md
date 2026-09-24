### Added

- An execution records when it ended: `ended_at` on the stored record and
  on `%StatifierPersistence.Execution{}` is stamped by the first write
  that takes the execution to `:completed`, `:failed` or `:cancelled`, and
  no later write moves or clears it. It is `nil` for an execution that
  has not ended, and for a row that was already terminal before V08.
- `StatifierPersistence.Executions.ended?/1` answers whether an
  execution carries that stamp.
- V08 of the migrations helper adds the nullable `ended_at` column to the
  executions table and an index on it. Run it before deploying this
  version: the generated execution schema reads the column on every
  query, so an executions table without it fails every read.
- `StatifierPersistence.Storage.Adapter.execution_record/0` carries
  `ended_at`, and `update_execution/2` keeps a stored stamp over the one
  a later record carries. The shared conformance suite checks both
  halves, so an adapter of your own must store the field and honour the
  rule.
