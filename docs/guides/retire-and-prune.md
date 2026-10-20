# How to retire a chart and prune finished executions

This guide shows you how to stop carrying what a finished library loan
leaves behind: how to retire a chart nothing can resume any more, how to
teach a retirement about state held outside this package, and how to prune
the position blobs and input logs of executions that have ended. The example
is a library loan: one execution per loan of a copy to a patron, on a chart
that waits for the copy's return after its due date. The first two parts use
a store built as in [How to set up the Ecto adapter](ecto-adapter.md);
what a prune leaves in place, and which rows you may delete yourself, is on
[What a finished execution leaves behind](../retention.md).

## Teach a retirement about state outside this package

Some of what holds a chart in use is not in this package's tables: a
pending timer or an address row lives in your own store, and this package
depends on neither. Tell it about that state by implementing
`StatifierPersistence.PinSource`, whose single callback answers named counts
for one content hash, and by passing the source modules in when you ask for
a retirement.

The example is a durable timer queue that holds a reminder for every loan
whose copy is due back:

    defmodule MyApp.TimerPins do
      @behaviour StatifierPersistence.PinSource

      @impl true
      def pins(_content_hash, %{execution_ids: execution_ids}) do
        %{pending_timers: MyApp.Timers.count_scheduled_for(execution_ids)}
      end
    end

`context` carries `:execution_ids`, the ids of the `:active` executions on
that hash. A source that knows executions and not hashes - the reminder
queue above knows loans - can answer without learning this package's key.

A source that cannot answer raises rather than answering zero, and the
refusal names the module. A source that throws or exits - a call that times
out inside it - is refused the same way, with its own reason.

## Retire a chart

A chart is stored once per content hash and stays for the life of the store.
When you want to stop carrying the bytes of a chart nothing can resume, call
`StatifierPersistence.Executions.retire_chart/4`. It either refuses with
every count holding the chart or tombstones the row: it keeps the row and its
content hash, records `retired_at` and `retired_by`, and nulls the two blob
columns.

    case Executions.retire_chart(store, content_hash, [MyApp.TimerPins],
           retired_by: "ops@example.test") do
      {:ok, retired} ->
        {:retired, retired.retired_at}

      {:error, {:pinned, counts}} ->
        {:still_in_use, counts}

      {:error, {:pin_source_failed, {module, reason}}} ->
        {:ask_again_later, module, reason}
    end

The third argument is the list of pin sources; pass `[]` when you have none.

### Read what pins a chart

Four things pin a chart and each refuses:

- an execution row on the hash in the `:active` or the `:needs_migration`
  status,
- a durable child whose linkage pin names the hash while its parent is in one
  of those two,
- a position row on the hash,
- any non-zero count from a pin source.

An execution that has finished pins nothing. Its counts are reported in a
refusal and never cause one, which is what keeps a chart retirable once its
traffic is over.

A `:needs_migration` execution is one a migration parked on its chart. It
takes no event until you put it back to `:active` or move it, as [How to move
executions onto a newer chart](move-executions.md) shows, and `fail/4` and
`cancel/3` end it as they end an `:active` one.

To find candidates first, ask `Executions.executions_on/2`. It is not a
retirability test on its own, because it reports the finished arms and
leaves out the position rows and your own sources.

A refusal carries every count it knows, so one answer says everything holding
the chart. A source that could not answer is a different arm and carries no
counts at all: the walk stopped, so no complete count exists, and a partial
one in the shape of a whole one is worse than none.

### What a retired hash does afterwards

The hash is terminal on both chart doors: `fetch_chart/2` answers
`{:error, {:chart_retired, info}}` rather than `:chart_not_found`, and
`save_chart/3` refuses the same arm rather than reviving the row. If you
retire a hash you still wanted, re-author the document and save the result
under its new hash.

### Retire on a backend other than Postgres

Retirement needs migration V07 and a store whose two chart blob columns are
nullable, which V07 can only arrange on Postgres. Elsewhere
`Storage.chart_retirement_supported?/1` answers `false` and the retirement
refuses at open with `{:error, :chart_retirement_unsupported}`, naming the
limit instead of failing on a constraint. If you are on another backend and
want the capability, alter those two columns in a migration of your own.

### When a chart is retired

There is no clock here. Nothing retires on its own or on a schedule, no call
takes a duration, and when a chart should go is your policy.

On Postgres a retirement and the creates and migrations on its chart are
ordered by a per-chart advisory lock. [What the chart lock
reaches](../chart-lock.md) says what waits on what, why the lock's key is
scoped by the store and not by a tenant, the one way a transaction of your
own can deadlock on it, and what it means for test suites running in
parallel.

## Prune finished executions

A finished execution keeps its last position blob and, on an adapter that
keeps one, its whole input log. Nothing in this package reads either once
the loan has ended. Clear both for every execution that ended before a `DateTime` you
pass:

    cutoff = DateTime.add(DateTime.utc_now(), -90, :day)

    {:ok, %{executions: pruned, position_blobs: blobs, inputs: inputs}} =
      StatifierPersistence.Retention.prune(store, cutoff)

`StatifierPersistence.Retention.prune/3` works in batches and keeps the
execution row: its status, answer and `ended_at` stay, so the drained query
still counts it and a parent can still read a child's answer. As with
retirement, the cutoff is your policy and no call takes a duration.

To prune one partition, or to prune inside a transaction of your own, see the
sections of the same names on [What a finished execution leaves
behind](../retention.md#pruning-one-partition). That page also says what a
prune clears, which rows you may delete yourself and which you must not.

The records behind these calls are [the retention and
retirement record](https://github.com/riddler/statifier_persistence/blob/main/docs/adr/0012-retention-and-retirement.md)
and [the pruning record](https://github.com/riddler/statifier_persistence/blob/main/docs/adr/0016-pruning-finished-executions.md).
