# How to list executions by host scope and record inputs for replay

This guide shows you how to do two things the Ecto adapter supports beside
the core store: tag an execution with your own scope ids and list executions
by them, and keep a log of the events an execution was handed so it can be
replayed. The example is a library loan: one execution per loan of a copy to a
patron, and a circulation screen that lists every loan for one branch. Both
parts assume a store built as in [How to set up the Ecto
adapter](ecto-adapter.md).

## List executions by host scope

An execution record carries engine identities and opaque blobs. Nothing on it
answers the question a multi-tenant host asks first - "list the executions for
scope X" - so an execution can carry one optional, opaque `metadata` map,
stored beside it and handed back unchanged (ADR-0006).

### Tag the execution at create

Tag the execution with the scope ids your host already keys its own tables by:

    {:ok, execution, _machine_state} =
      StatifierPersistence.Executions.create(store, "loan_01H8", machine,
        executor: MyApp.Executor,
        metadata: %{
          "tenant_id" => "lib_01H8X",
          "branch_id" => "branch_4471"
        }
      )

### List by an equality match

Read the executions back with an equality match on every pair:

    {:ok, executions} =
      StatifierPersistence.Storage.Ecto.list_executions_by_metadata(store.opts, %{
        "branch_id" => "branch_4471"
      })

Equality on all given pairs is the whole query surface: no ranges, no partial
matches, no ordering guarantee. Anything richer is a query you write against
your own column - the table name is yours to configure, so that is a supported
thing to do. The V02 migration adds the column as nullable `jsonb` with no
index of its own, because which pairs you query by is your call. V03 (see
[Upgrading a host from 0.13 to 0.25.0](../upgrading.md)) adds the one
containment index this package's own settlement query needs, a GIN
`jsonb_path_ops` index on the whole column; an expression index on particular
keys, or the wider `jsonb_ops` operator set, is still yours to add when the
volume asks.

### Keep identities in the map, never personal data

Keys and values are host identities - a tenant id, a branch id, a correlation
id - and never a patron's name, an email address, a postal address, a card
number (a library card or a payment card), or any other personal data. This is
a rule of the contract, not advice: `:blob_type` encryption covers the payload
columns (`identity_blob`, `chart_blob`, `position_blob`, `outcome_blob`, and
the input log's `input_blob`) and does not reach this one, so anything you file
here is at rest in the clear no matter how the blobs are configured. The map is
opaque to this package by design, so nothing here can inspect a value and
reject it - the rule is kept by you.

### Handle an adapter that refuses the map

An adapter that cannot store the map refuses a non-empty one at the create with
`{:error, :metadata_unsupported}`, so you learn on the first call rather than
finding a silently dropped scope later. An empty or absent map is never
refused. The shipped in-memory and Ecto adapters both support it; a third-party
adapter that does not is still conformant, and the conformance suite tests both
answers. The Ecto adapter refuses at the same point for a value `jsonb` cannot
hold - a tuple, an atom, a pid, or a binary that is not valid UTF-8 - rather
than storing something that is not what you handed it. The map is write-once:
it is set at create and a later step or abandonment carries it forward
untouched.

### Scope the charts yourself

An execution is the only thing this package scopes for you, and only through
that map. A chart is not: `StatifierPersistence.Storage.save_chart/3` keys a
chart on its content hash alone, so two branches storing byte-identical charts
share one chart row. Tenant-qualify your own per-chart rows in your own tables
- folding a namespace into the hash would change what a chart's identity is,
which is statifier-ex's contract and not an option this package offers.

## Record an execution's inputs for replay

A durably stepped execution stores a chart, a position and an execution
record, and none of them is an input. The position is the execution's
*current* configuration, overwritten on every step, so by construction the
history an offline replay needs is destroyed by the mechanism that makes the
execution durable. An optional per-execution input log closes that gap
(ADR-0010).

### Ask whether the adapter keeps a log

The log is opt-in by export, exactly as the `metadata` map is: an adapter that
exports `supports_input_log?/1` and answers `true` keeps one, and an adapter
that does not stores no inputs and behaves exactly as it did before. **Nothing
refuses an execution over it** - a diagnostic facility must not break the
execution it is diagnosing - so ask before you rely on it:

    StatifierPersistence.Storage.input_log_supported?(store)

### Read the log

The Ecto adapter keeps the log on every backend, in the V05 table. Each entry
is the `%Statifier.Event{}` the interpreter was handed, verbatim, stamped with
the public door it entered by and a dense zero-based ordinal:

    {:ok, entries} = StatifierPersistence.Executions.inputs(store, "exec_1")

    Enum.map(entries, &{&1.seq, &1.door, &1.event.name})
    #=> [{0, "step", "advance"}, {1, "answer_parent", "done.invoke.call"}]

One log belongs to one execution. A durable subchart's child is an ordinary
execution, so it has its own log; the parent's holds the answer it saw at the
`answer_parent` door, and not the child's inputs. Only inputs an interpreter
actually saw are recorded - a delivery to a terminal execution, or to an
invocation the chart has since cancelled, is discarded and appends nothing,
because a replay that applied it would produce a different execution than the
one that happened.

### Decide to turn it on as a retention choice

Turning the log on is a data-retention decision, not a debugging switch. Chart,
position and identity blobs are engine-shaped; an event's `data` is your own
values, and this is the first thing this package stores that can hold personal
data, such as a patron's contact details or a card number. So `input_blob` is a
blob in the `:blob_type` sense (see [How to encrypt the blob columns and place
host columns](encrypt-and-place-columns.md#encrypt-the-blob-columns)), and
it is *not* the `metadata` map, which stays in the clear by design.

### Cap how much accumulates

Bound how much accumulates with a per-execution cap declared where every other
adapter setting is:

    {:ok, store} =
      StatifierPersistence.Storage.new(
        StatifierPersistence.Storage.Ecto,
        persistence: MyApp.Persistence,
        input_log_cap: 500
      )

The default is `:infinity`; a bounded default would be this package silently
truncating your log. Past the cap the log **closes itself**: the last slot is
written as a marker entry whose `event` is `nil`, every later append is
refused, and the step itself succeeds and the execution carries on. The marker
is the point - a truncated log that looked complete would satisfy every check a
replay makes while replaying an execution that never happened.

### Replay the log

The replay itself is `statifier_ui`'s (`StatifierUI.Trace.Replay.from_events/4`);
ADR-0010 decision 8 names the mapping from a stored entry to what that function
takes, and nothing in this package depends on `statifier_ui` to say so.
