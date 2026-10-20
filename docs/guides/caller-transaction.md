# How to step inside a caller's transaction

This guide shows you how to make an execution's writes and your own rows
commit together on the Ecto adapter: by stepping inside a transaction you
open, by having your executor write its timer rows in the step's own
transaction, and by delivering events from more than one process while a
step is in flight. The example is a library loan: one execution per loan of a
copy to a patron, a loan row of your own that maps the copy's barcode to the
loan's execution id, and a reminder table your executor fills with the
loan's delayed sends. Every part assumes a store built as in [How to set up
the Ecto adapter](ecto-adapter.md).

## Write your own rows in the same transaction as a step

When you keep rows of your own beside an execution - the loan row that maps
a copy's barcode to the loan's execution id, say - open one transaction on
your own repo and call `Executions.create/4` and `Executions.step/5` inside
it, from the same process. The two doors then write through your
transaction rather than one of their own. Build the `store` over your own
repo: its persistence module's `repo:` is `MyApp.Repo`, as in [How to set up
the Ecto adapter](ecto-adapter.md).

    MyApp.Repo.transaction(fn ->
      {:ok, _execution, _state} =
        StatifierPersistence.Executions.create(store, execution_id, machine, executor: MyApp.Executor)

      {:ok, _execution, _state} =
        StatifierPersistence.Executions.step(store, execution_id, machine, event, executor: MyApp.Executor)

      # ... your own writes: the loan row for the copy's barcode ...
    end)

This works because `lock_execution/3` opens its transaction with
`repo.transaction/1`, and Ecto runs a transaction opened on the same repo
in the same process as part of the one already open.

### What to expect from the transaction

The contract, pinned by
`test/statifier_persistence/ecto/caller_transaction_test.exs` against real
Postgres:

- **Which doors.** `create/4` and `step/5`, called directly, over the
  Ecto adapter and the default serialization. A rollback leaves no
  execution row and no input log row behind; a commit keeps the
  execution and the input row `step/5` wrote, and later steps append
  after it as usual. The `StatifierPersistence.Driver` doors are not
  part of this contract: a child's drive answers its parent after its
  own exclusion is released (`Executions.cascade_cancel/3`'s doc says
  why that order matters), and inside a caller's transaction nothing is
  released before the commit. (The two sentences on the Driver doors are
  read from the code, not pinned by that test.)
- **Effects fire before the commit.** Both doors hand their effects to
  the executor before they write the execution record, and neither waits
  for your transaction. A rollback does not un-fire an effect: whatever the
  executor did outside the repo has happened. Only writes the executor
  itself makes through the same repo, from the calling process, join the
  transaction and roll back with it (Ecto's ordinary rule, not this
  package's).
- **The lock joins the outer transaction.** The per-execution advisory
  lock and row lock are transaction-scoped, so inside your transaction
  they are held until you commit or roll back, not until the door
  returns. Another connection stepping the same execution waits for your
  commit. A caller that touches two executions in one transaction holds
  both exclusions to the end, and the order it takes them in is the
  caller's to keep consistent. (That last sentence, on two executions in
  one transaction, is read from the code, not pinned by that test.)

### Treat an `:execution_exists` refusal as the end of the transaction

`create/4` returns `{:error, :execution_exists}` for an id that already
exists, but the refusal is a failed `INSERT` on the unique index, and
Postgres refuses every later statement in that transaction. Your
transaction ends in `{:error, :rollback}` and its other writes are rolled
back. Retry the lookup in a new transaction. The refused create has also
already fired its initialize effects, exactly as it does outside a caller's
transaction. (Pinned by the same test.)

## Commit timer rows with the step's position

When you keep the loan's delayed sends in your own table - the rows you
re-arm after a restart, such as a hold-expiry reminder, and the rows a
`<cancel>` removes when the patron picks the copy up - commit those writes
in the same transaction as the position of the step that produced them.
statifier-ex's ADR-0074 decision 2 states the rule and what each split
order loses: a position saved before its cancel's removal can leave the
cancelled send pending under a position that will never run the `<cancel>`
again, so the send fires.

### Write the rows from the executor, through the same repo

On the Ecto adapter, under the default serialization, the join holds by
construction when the executor writes its timer rows through the same repo,
from the process that called the door. A step's effects reach the executor
before the new position is written (the `c:StatifierPersistence.Executor.execute/2`
doc), and both run inside the one transaction `lock_execution/3` opens with
`repo.transaction/1`. While that transaction is open, any write through the
same repo in the same process, or a nested transaction on it, runs on the
connection the step's transaction holds (Ecto's ordinary rule, not this
package's). The executor needs no transaction of its own: its writes commit
or roll back with the position.

    defmodule MyApp.Executor do
      @behaviour StatifierPersistence.Executor

      @impl true
      def execute({:send_delayed, delayed}, context) do
        # Keyed by {execution_id, ordinal}: a re-driven step re-emits the
        # same ordinal, so the insert is idempotent.
        MyApp.LoanReminders.arm(context.execution_id, delayed)
      end

      def execute({:cancel, cancel}, context) do
        MyApp.LoanReminders.cancel(context.execution_id, cancel.send_id)
      end

      def execute(_effect, _context), do: :ok
    end

Here `MyApp.LoanReminders` writes through `MyApp.Repo`, the repo the store's
persistence module names. Pinned by
`test/statifier_persistence/ecto/step_timer_store_transaction_test.exs`
against real Postgres:

- **A crash after a step's cancel leaves both halves as they were.** When
  the step raises after the executor has removed the cancelled row and
  before the position is written, the row is still pending and the saved
  position is still the one before the step. Re-driven without the crash,
  the step commits the removal and the new position together.
- **A crash after a create's delayed-send insert leaves neither.** No
  timer row and no execution row are committed.

### Key the rows for a failed save and a re-driven step

When the position save that follows a step's effects answers an error, and
`lock_execution/3` opened the transaction itself, the transaction rolls
back with the executor's writes in it and the step still answers the save's
error; redelivered, the whole step runs again. Every other answer the step's
body returns commits: a budget-exhausted step answers
`{:error, {:budget_exhausted, payload}}` after its `:failed` record and your
rows are written. Inside a transaction of your own the step answers the same
error and commits nothing on its own: the rollback, to a savepoint or of the
whole transaction, is yours. (Pinned by the same test, all three cases.)
Effect delivery is at-least-once either way: key the rows so a re-driven
step's re-emitted effects find them (a re-emitted cancel that matches
nothing is a no-op).

### Check that the join is yours to provide

Each case below is read from the code, not pinned by that test, except the
one sentence the first case names:

- **Another serialization strategy.** A host's own `serialization:` strategy
  replaces `lock_execution/3`, and this package opens no transaction of its
  own around the step, so the join is whatever that strategy provides. (That
  a failed position save under your own strategy answers the same error and
  commits is pinned by the same test.)
- **The in-memory adapter.** Its `lock_execution/3` takes a lock and no
  transaction; there is nothing to join.
- **Another repo or another process.** A timer store on a different repo,
  or written from another process (a `Task`, a message to a GenServer),
  runs on its own connection and commits on its own. A host whose timer
  store cannot share the step's transaction does not meet ADR-0074
  decision 2, and this package cannot close that gap for it.
- **Inside a caller's transaction.** The rows commit when your
  transaction does, with the position, as [Write your own rows in the same
  transaction as a step](#write-your-own-rows-in-the-same-transaction-as-a-step)
  describes.

## Deliver an event while a step is in flight

When you deliver events from more than one process - a controller that
takes every branch's return scans with no partitioner in front of it, say -
you will sooner or later call `Executions.step/5` for an execution while
another `step/5` for the same execution is still running. There is no
separate door for that case, because `step/5` already serializes it: every
step runs its whole fetch-to-persist tail inside the execution's
serialization strategy, and the default strategy is the adapter's own
`lock_execution/3`. What a second `step/5` does while the first holds that
lock, per adapter:

| Storage | The second `step/5` while the first holds the lock |
|---|---|
| The Ecto adapter (Postgres) | Waits on the transaction-scoped advisory lock, then steps |
| `StatifierPersistence.Storage.InMemory` | Waits, retrying the lock every 5ms, then steps |
| An adapter that exports no `lock_execution/3` | Refused with `{:error, {:serialization, :not_supported}}` whether or not another step is in flight; nothing is fetched or written |
| Any adapter under a host's own `serialization:` strategy | Whatever that strategy does; this package waits on nothing of its own |

The first two rows are pinned by the test named below. The third is
pinned for `create/4` by `test/statifier_persistence/executions_test.exs`
and reaches `step/5` through the same default strategy; the fourth is
read from the code.

### What the second call answers

Pinned by `test/statifier_persistence/held_lease_test.exs`, on the Ecto
adapter against real Postgres and on the in-memory adapter's lock:

- **The second call waits, then steps.** It does not return while the
  first holds the lock, and it appends nothing to the input log until
  then. Once the first has persisted, the second reads the execution
  record and the position the first one wrote and steps from there, so
  both return `{:ok, execution, machine_state}` and the input log holds
  the first call's event before the second's.
- **A step the first one made terminal is discarded.** If the first
  step ends the execution - the copy is returned and the loan closes -
  the second returns `{:discarded, execution}` once it gets the lock, and
  the log does not carry its event: the same answer any delivery to a
  terminal execution gets.

### Plan for the wait

Each bullet below is read from the code, not pinned by that test:

- **No call is refused or discarded for being busy.** From `step/5`,
  `{:discarded, _}` means a terminal execution record, an event builder
  that declined, or a stored position that turned out to be terminal,
  never "the lock was held"; a held lock only ever makes a call wait, and
  a wait a timeout cuts short raises (the next bullet).
- **Neither shipped adapter bounds the wait.** The in-memory adapter
  retries until the lock frees. The Ecto adapter passes no timeout of its
  own to the lock query, so what ends a long wait there is the repo's
  query timeout or a timeout the server enforces. Either one raises out of
  `step/5`: the lock query runs through `repo.query!`, so the lock's
  transaction rolls back and the driver's exception propagates to your
  call rather than coming back as an `{:error, _}` answer. A waiting call
  on the Ecto adapter holds a pooled connection for the whole wait,
  because its transaction is open before the lock query runs, so many
  deliveries waiting on one execution can use up the pool.
- **Order is the lock's.** A call that arrives while another holds the
  lock steps after it. Among several calls all waiting at once, the
  order they step in is the order the lock grants them - Postgres's lock
  queue on the Ecto adapter, whichever retry lands first on the in-memory
  one - and this package promises no more than that.
- **Inside a caller's transaction the lock is the caller's.** A `step/5`
  called inside a transaction you opened holds the lock until you commit
  or roll back (the caller-transaction test pins that for `create/4`,
  which takes the lock the same way), so a delivery from another process
  waits for your commit, not for `step/5` to return.
- **The wait is visible.** `[:statifier_persistence, :execution, :lock]`
  reports the wait for the lock as its `duration`
  ([Telemetry](../telemetry.md)), which is where contention on one
  execution shows up.
