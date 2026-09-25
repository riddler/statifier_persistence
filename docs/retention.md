# What a finished execution leaves behind

An execution that has ended keeps three things in your store: its row in
the executions table, the last position blob written on that row, and, if
your adapter keeps one, its whole input log. The row is history. The
position blob and the log are not needed by anything in this package once
the execution has ended, and the log holds your own event data, verbatim.

This page says what `StatifierPersistence.Retention.prune/3` clears, which
rows you may delete yourself for a finished execution, and which you must
not. The schema declares no foreign keys, so the database will not stop a
wrong delete. This page is the only guard.

The design is ADR-0016.

## Pruning

    cutoff = DateTime.add(DateTime.utc_now(), -90, :day)

    {:ok, %{executions: pruned, position_blobs: blobs, inputs: inputs}} =
      StatifierPersistence.Retention.prune(store, cutoff)

`prune/3` selects every execution whose status is `:completed`, `:failed`
or `:cancelled` and whose `ended_at` is before `cutoff`. For each one it
sets `position_blob` to `NULL` and deletes all of its input log rows. The
row itself stays, with its status, failure, metadata, answer and
`ended_at`.

- **The cutoff is yours.** It is a `DateTime`, and `prune/3` raises on a
  number of days, a `Duration` or a `Date`. This package has no retention
  window and no default. How long you keep a finished execution's leftovers
  is your policy, and you run the prune when that policy says to.
- **An execution with no `ended_at` is never pruned.** That includes a row
  that was already finished before migration V08 added the column: its end
  time is not stored anywhere. It gets a stamp only when a later terminal
  write reaches it.
- **A stamped row that is not terminal is never pruned.** A stamp stays on
  a row that a later write put back to `:active`, and that execution can
  still take a step.
- **It works in batches and can be repeated.** `batch_size:` (default 500)
  bounds each transaction. Each batch commits on its own, so a call that
  fails part-way leaves the earlier batches done. Calling again with the
  same cutoff carries on, and a call with nothing left to do answers zeros.
- **It needs an adapter that declares it.** Both shipped adapters do. The
  in-memory adapter keeps no input log, so it clears position blobs only.
  An adapter of your own declares it by exporting
  `supports_execution_pruning?/1` and `prune_executions/4`; one that does
  not gets `{:error, :execution_pruning_unsupported}`, and
  `StatifierPersistence.Storage.execution_pruning_supported?/1` tells you
  in advance.

### Pruning one partition

If your tables carry a column of your own that partitions them, placed
with `:leading_columns` on `use StatifierPersistence.Ecto`, `scope:`
confines a prune to the rows that hold it:

    StatifierPersistence.Retention.prune(store, cutoff, scope: [tenant_id: tenant_id])

`scope:` is a keyword list of column equalities. Every statement each
batch runs carries all of them: the selection, the input log check inside
it, the input log delete and the position blob update. So a prune you run
inside one partition's transaction reads and writes no row of another.

- **The columns must be your `:leading_columns`.** The Ecto adapter raises
  `ArgumentError` for any other column before it runs a statement.
- **A scope is never empty and never `nil`.** `prune/3` raises on
  `scope: []`, so a scope your code computed to nothing cannot prune every
  partition. It also raises on a `nil` value, because an equality with
  `NULL` matches no row. To prune across every partition, leave `scope:`
  out.
- **The in-memory adapter cannot scope.** Its records have no columns of
  yours, so it answers `{:error, :unscoped_adapter}` for any `scope:` and
  clears nothing.

After a prune, `Executions.inputs/2` answers `{:ok, []}` for that
execution, which is also what an execution that took no input answers. A
load of its position answers `{:error, :execution_position_missing}`, which
is also what an execution that failed at creation answers. No read tells
you an execution was pruned. If something you run reads input logs, for
example a replay tool, decide which executions it may read from their
`ended_at` and your own cutoff.

## Rows you may delete for a finished execution

"Finished" here means the same thing it means to `prune/3`: the status is
`:completed`, `:failed` or `:cancelled`, and it has an `ended_at`.

| Row | Why it is safe |
|---|---|
| Its input log rows (the inputs table, by `execution_id`) | Nothing in this package reads the log; `Executions.inputs/2` is a diagnostic read for you. Delete all of an execution's rows or none of them. `prune/3` does this for you. |
| Its `position_blob`, set to `NULL` on the executions row (not the row itself) | Nothing in this package loads a finished execution's position. `step/5`, `fail/4` and `cancel/3` discard a finished execution before loading anything, and `migrate/4` refuses one. `prune/3` does this for you. |
| A positions row, keyed by session, for a session you will never resume | This package cannot tell when a session is done. The positions table has no end stamp and no link to an execution, so `prune/3` never touches it. Deleting the row also releases the chart pin it holds, which can make that chart retirable (see "Retiring a chart" in the README). |

## Rows you must not delete

| Row | What breaks |
|---|---|
| The execution row itself | The drained query (`Executions.executions_on/2`) stops counting it. A parent that has not settled yet reads a child's status and answer from this row. A re-driven child create would no longer find the child, and would start it again from the beginning. And the id becomes free to reuse, for an execution nothing would tell apart from the old one. |
| A charts row | Retire a chart with `Executions.retire_chart/4`, which refuses while anything still needs it. A deleted row loses its tombstone: `fetch_chart/2` answers `:chart_not_found` rather than the retired arm, and a later `save_chart/3` brings the chart back. If you read a chart back through `fetch_chart/2` to resume an execution, nothing on that hash can be resumed. |
| The input log or position of an execution that has not finished | The execution can still take a step. With its position gone, the step fails with `:execution_position_missing`. With its log gone, the next input is written at ordinal 0 again, and the log reads as if the execution had started there. |
| Some, but not all, of an execution's input log rows | A log with a gap looks complete and is not. A replay built from it replays a different execution. |

## What pruning does not do

- **It keeps the answer and the metadata.** `outcome_blob`, `failure` and
  `metadata` stay on the row, because a parent may still need the answer.
  Metadata should hold host identities only, never personal data (see
  ADR-0006). If your chart's answers carry personal data, pruning does not
  remove it.
- **It does not touch keys or copies.** If you encrypt the blob columns
  (`:blob_type`), pruning removes the ciphertext from the live rows. It
  does not rotate or destroy a key, and it does not reach your backups.
- **It does not cascade.** A parent and its durable children are each
  pruned on their own `ended_at`. Either order is safe, because the rows
  stay.
- **It has nothing to clear from the trace.** This package emits telemetry
  and stores none of it.
