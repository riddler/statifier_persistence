# How to move executions onto a newer chart

This guide shows you how to move executions that are waiting onto the chart
from a document's next revision: one execution, a parent with the durable
children it invoked, or every execution on a chart. The example is a library
loan: a hold on a copy that waits for the patron to collect it, on a document
that has since been edited.

An execution stays on the chart it was created on. When a document is edited
and a new revision saved, an execution already waiting keeps its old chart,
and keeps that chart pinned, until you move it. Nothing moves one for you:
saving a chart, creating an execution and stepping one never migrate
anything. Three calls move executions when you ask:

- `StatifierPersistence.Executions.migrate/4` moves one execution.
- `StatifierPersistence.Executions.migrate_tree/4` moves a parent and the
  durable children it invoked together.
- `StatifierPersistence.Executions.migrate_batch/3` takes one plan and moves
  every `:active` and `:needs_migration` execution on its `from` hash, one at
  a time rather than as one unit: `migrate/4` for an unlinked execution and
  `migrate_tree/4` for a linked one. `dry_run: true` previews it.

## Move one execution

A library hold waits in `awaiting_pickup`. Entering that state scheduled the
pickup deadline as a delayed send, and started two invocations: a patron
notice (`<invoke id="notice">`) and a desk slip (`<invoke id="slip">`). The
next revision of the document renames the state `ready_for_pickup`.

A `Plan` says how a position crosses between the two charts. A state it does
not name maps to the state of the same id, so the plan names only the rename:

```elixir
alias StatifierPersistence.Migration.Plan

# old_machine is the compiled machine the hold was created on; new_machine
# is the chart compiled from the document's next revision.
{:ok, new_blob} = Chart.to_binary(new_machine)
:ok = Storage.save_chart(store, new_machine, new_blob)

{:ok, plan} =
  Plan.new(
    from: old_machine.identity.content_hash,
    to: new_machine.identity.content_hash,
    states: %{"awaiting_pickup" => "ready_for_pickup"}
  )

Executions.migrate(store, "hold_8812", plan,
  from_machine: old_machine,
  to_machine: new_machine
)
#=> {:ok, execution, %{from_content_hash: ..., to_content_hash: ..., dropped: []}}
```

The `Plan` also has a string-keyed map form, `Plan.to_map/1` and
`Plan.from_map/1`, for a plan you store as JSON.

### Keep a pending timer

The package stores no timer, so the pickup deadline stays in your queue with
its time unchanged, and the plan keeps it by mapping the state around it. A
plan that leaves such a state unmapped, or drops it, needs a pin source passed
as `pin_sources:` (see [How to retire a chart and prune finished
executions](retire-and-prune.md)), and without one the call refuses with
`{:no_pin_source, states}` before it reads the execution. A source that
counts a pending timer for an unmapped state refuses with a
`{:pending_timers, states, counts}` finding, so map the state around the
timer to keep it.

### Read the answer

The migration is whole or it does not happen. Every check and the whole
transform come before the one write, and the write moves the execution to the
new hash at `:active`. `migrate/4` answers:

- `{:ok, execution, migrated}`: the execution on the new chart, and the two
  hashes with the `dropped` states that were in its configuration.
- `{:error, {:migration_refused, findings}}`: the plan does not fit this
  execution. Every finding is listed at once, and nothing was written.
- `{:parked, {:migration_refused, findings}}`: the same refusal under
  `on_failure: :park`, described below.
- `{:error, reason}` for the other refusals: `{:invalid_plan, findings}` for a
  plan that does not fit the two charts,
  `{:no_pin_source, states}`, `{:pin_source_failed, {module, reason}}`,
  `{:chart_retired, info}`, `{:terminal_execution, execution}`,
  `{:not_on_from_chart, stored_hash, plan_from}` and
  `{:linked, execution}` (a durable child is moved with `migrate_tree/4`).
  Nothing is written for any of them, under either `on_failure:` value.

### Fix a plan that is refused for its invocations

A refusal worth knowing is the one the patron notice shows. Suppose the next
revision also prints the desk slip first, so the two `<invoke>` elements of
`ready_for_pickup` come in the other order. An invocation keeps its ordinal
by default, the notice would land on the slip's element and take that
element's finalize and autoforward, and the rename plan above is refused for
both:

```elixir
{:error, {:migration_refused, findings}} =
  Executions.migrate(store, "hold_8812", plan,
    from_machine: old_machine,
    to_machine: new_machine
  )

findings
#=> [
#=>   {:invocation_element_changed, {"awaiting_pickup", 0}, {"ready_for_pickup", 0}},
#=>   {:invocation_element_changed, {"awaiting_pickup", 1}, {"ready_for_pickup", 1}}
#=> ]
```

An invocation is named by its state and its ordinal, counted from `0` in
document order. The plan that names both moves lands each invocation on the
element authoring its own `id`, and migrates:

```elixir
{:ok, plan} =
  Plan.new(
    from: old_machine.identity.content_hash,
    to: new_machine.identity.content_hash,
    states: %{"awaiting_pickup" => "ready_for_pickup"},
    invocations: [
      {"awaiting_pickup", 0, "ready_for_pickup", 1},
      {"awaiting_pickup", 1, "ready_for_pickup", 0}
    ]
  )
```

The `migration_finding` type in `StatifierPersistence.Executions` lists every
other finding and what you do about each.

## Park a refused execution

By default a refusal leaves the execution as it was. With
`on_failure: :park` a refusal of the plan against the execution,
`{:migration_refused, findings}`, writes one thing: the execution's status
becomes `:needs_migration`, still on the old chart at the position it was
parked at. The call answers `{:parked, {:migration_refused, findings}}`.
Every other refusal in the list above writes nothing under either value.

A parked execution takes no event. A delivery to it answers
`{:error, {:needs_migration, execution}}`, nothing is appended or stepped,
and the retry is your job queue's. It still pins its chart:
`Executions.executions_on(store, old_hash)` counts it under
`needs_migration`, and `retire_chart/4` refuses while it waits. There are two
ways out:

- Correct the plan and call `migrate/4` again. A `:needs_migration`
  execution is migrated as an `:active` one is, and a success writes it back
  at `:active` on the plan's `to` chart.
- Decide it should go on unmigrated and call `Executions.unpark/3`, which
  puts it back to `:active` on the chart it was pinned to. Nothing is
  replayed; a delivery refused while it was parked is delivered again by you
  or not at all. An `:active` execution answers `{:ok, execution}` and
  nothing is written, and a terminal one answers `{:discarded, execution}`.

`fail/4` and `cancel/3` end a parked execution as they end an active one.

## Move a tree

A durable child's linkage pins the child's own chart, so `migrate/4` moves
neither a child nor its pin. When the hold invoked a pickup-notice execution
as a durable child and both documents were edited, `migrate_tree/4` moves the
hold and its notice together, or neither:

```elixir
Executions.migrate_tree(
  store,
  "hold_8812",
  %{"hold_8812" => hold_plan, "notice_8812" => notice_plan},
  machines: %{
    old_hold_hash => old_hold_machine,
    new_hold_hash => new_hold_machine,
    old_notice_hash => old_notice_machine,
    new_notice_hash => new_notice_machine
  },
  on_failure: :park
)
#=> {:ok, [{notice_execution, migrated}, {hold_execution, migrated}]}
```

`plans` maps an execution id to the plan for that node, and `machines:` holds
the `from` and `to` machine of every plan, by content hash. A node you leave
out of `plans` is not touched, and if it is live it must still resolve
against its parent as the parent will stand after the move. Every named node
is checked as `migrate/4` checks one, every refusal is collected before
anything is written, and the write is one unit, so the tree lands or none of
it does. The answers:

- `{:ok, moved}`: a `{execution, migrated}` pair per named node, children
  first and the root last.
- `{:error, {:tree_refused, refusals}}`: one or more nodes refused, keyed by
  execution id. A node's refusal is what `migrate/4` would answer for it,
  except `{:linked, _}`, which a tree never answers, or
  `{:machine_missing, hash}`, or `{:child_unresolved, parent_id, invoke_id}`.
- `{:parked, {:tree_refused, refusals}}`: under `on_failure: :park`, when
  every refusal is one that parks. Every named node, including one whose own
  plan would have applied, is written `:needs_migration` in the same unit.
  A node you left out of `plans` is not parked. Only `{:migration_refused, _}`
  and `{:child_unresolved, _, _}` park; any other refusal parks nothing, and
  the answer is the `{:error, {:tree_refused, refusals}}` above.
- `{:error, :tree_migration_unsupported}` for a store whose adapter does not
  declare the tree write, and `{:error, {:not_in_tree, ids}}` for ids in
  `plans` that are not nodes of the tree.

[The migration plan](https://github.com/riddler/statifier_persistence/blob/main/docs/adr/0013-the-migration-plan.md),
[the `:needs_migration` status](https://github.com/riddler/statifier_persistence/blob/main/docs/adr/0014-the-needs-migration-status.md)
and [the tree migration](https://github.com/riddler/statifier_persistence/blob/main/docs/adr/0015-the-tree-migration.md)
are the records behind these calls.
