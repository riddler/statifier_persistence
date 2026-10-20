# StatifierPersistence

[![CI](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_persistence/)
[![License](https://img.shields.io/hexpm/l/statifier_persistence.svg)](https://github.com/riddler/statifier_persistence/blob/main/LICENSE)

> **Pre-1.0.** Until `statifier_persistence` reaches v1.0, its public surface may change
> between minor releases, sometimes drastically: a release may rename modules,
> callbacks, table columns, telemetry events or error vocabulary with no
> compatibility shim. Every such change is recorded in
> [CHANGELOG.md](CHANGELOG.md) under a bold **Breaking** heading that says what
> to do about it. Pinning to an exact minor - `~> X.Y.0` - is the recommended way
> to consume the package until 1.0. What a host changes for each minor from 0.13
> on is on one page:
> [`docs/upgrading.md`](docs/upgrading.md).

Durable stepper and storage adapters for
[Statifier](https://github.com/riddler/statifier-ex).

Documentation lives on [hexdocs](https://hexdocs.pm/statifier_persistence/),
including the [Surviving a restart](docs/restart-demo.md) guide.

Statifier's pure interpreter contract (machine_state, event -> machine_state,
effects) makes a persistence-first execution model possible: load a persisted
position, step it, execute the effects, persist. Hosts running charts that
span days or survive deploys should not need long-lived Session processes at
all - but every host currently hand-rolls the loop, the storage guard, and the
crash semantics. This package is that loop, packaged.

## Installation

```elixir
def deps do
  [
    {:statifier_persistence, "~> 0.25.0"},
    # Optional, for the Postgres adapter:
    {:ecto_sql, "~> 3.10"}
  ]
end
```

## Documentation

- Do
  - [How to set up the Ecto adapter](docs/guides/ecto-adapter.md) - configure a persistence module, migrate, build the guarded store, and run on a backend that is not Postgres
  - [How to persist an execution and resume it in another process](docs/guides/persist-and-resume.md) - store an execution after every step and carry it on from another process with only its id
  - [How to drive a chart that calls out](docs/guides/drive-a-chart.md) - run an execution whose chart invokes your host, and fan one invocation out over N children
  - [How to list executions by host scope and record inputs for replay](docs/guides/host-scope-and-inputs.md) - tag an execution with your own scope ids and list by them, and keep an input log so an execution can be replayed
  - [How to step inside a caller's transaction](docs/guides/caller-transaction.md) - write your own rows in the same transaction as a step, commit timer rows with the step's position, and deliver events while a step is in flight
  - [How to encrypt the blob columns and place host columns](docs/guides/encrypt-and-place-columns.md) - put an encrypting Ecto type on the payload columns, and put a column of your own at a fixed position in every table the migrations helper creates
- Understand
  - [Documents, revisions, charts and executions, and why an execution is a durable row](docs/explanation/documents-revisions-charts-executions.md) - what the host keeps, what this package stores, and why an execution is a row that outlives every process

## Status

Early, under active development, and the API is not frozen before 1.0.
The storage-adapter behaviour with its identity guard, the in-memory
reference adapter, the execution lifecycle and executor seam, per-execution
serialization, and the Ecto layer (configurable keys/tables, versioned
migrations, and the Postgres adapter) all exist and are
conformance-tested.

## Pin sources

Some of what holds a chart in use is not in this package's tables: a
pending timer or an address row lives in a host's own store, and this
package depends on neither. A host teaches it about that state by
implementing `StatifierPersistence.PinSource`, whose single callback
answers named counts for one content hash, and by passing the source
modules in when it asks for a retirement. A source that cannot answer
raises rather than answering zero, and the refusal names the module. A
source that throws or exits - a call that times out inside it - is
refused the same way, with its own reason.

    defmodule MyApp.TimerPins do
      @behaviour StatifierPersistence.PinSource

      @impl true
      def pins(_content_hash, %{execution_ids: execution_ids}) do
        %{pending_timers: MyApp.Timers.count_scheduled_for(execution_ids)}
      end
    end

`context` carries `:execution_ids`, the ids of the `:active` executions
on that hash, so a source that knows executions and not hashes - a timer
queue over an advertising chart waiting for a click after an impression -
can answer without learning this package's key.

## Retiring a chart

A chart is stored once per content hash and stays for the life of the
store. When a host wants to stop carrying the bytes of a chart nothing
can resume, `StatifierPersistence.Executions.retire_chart/4` either
refuses with every count holding the chart or tombstones the row: it
keeps the row and its content hash, records `retired_at` and
`retired_by`, and nulls the two blob columns.

    case Executions.retire_chart(store, content_hash, [MyApp.TimerPins],
           retired_by: "ops@example.test") do
      {:ok, retired} ->
        {:retired, retired.retired_at}

      {:error, {:pinned, counts}} ->
        {:still_in_use, counts}

      {:error, {:pin_source_failed, {module, reason}}} ->
        {:ask_again_later, module, reason}
    end

Four things pin a chart and each refuses: an execution row on the hash
in the `:active` or the `:needs_migration` status, a durable child whose
linkage pin names the hash while its parent is in one of those two, a
position row on the hash, and any non-zero count from a pin source. A
`:needs_migration` execution is one a migration parked on its chart; it
takes no event until `Executions.unpark/3` puts it back to `:active` on
that chart, or a corrected plan through `Executions.migrate/4` moves it
onto the plan's `to` chart at `:active`, and `fail/4` and `cancel/3` end it as they
end an `:active` one. An
execution that has finished pins nothing - its counts are reported in
a refusal and never cause one - which is what keeps a chart retirable
once its traffic is over. Asking `Executions.executions_on/2` first
finds candidates; it is not a retirability test on its own, because it
reports the finished arms and leaves out the position rows and the
host's own sources.

A refusal carries every count it knows, so one answer says everything
holding the chart. A source that could not answer is a different arm
and carries no counts at all: the walk stopped, so no complete count
exists, and a partial one in the shape of a whole one is worse than
none.

Afterwards the hash is terminal on both chart doors: `fetch_chart/2`
answers `{:error, {:chart_retired, info}}` rather than
`:chart_not_found`, and `save_chart/3` refuses the same arm rather than
reviving the row. A host that retires a hash it still wanted
re-authors the document and saves the result under its new hash.

Retirement needs migration V07 and a store whose two chart blob columns
are nullable, which V07 can only arrange on Postgres. Elsewhere
`Storage.chart_retirement_supported?/1` answers `false` and the
retirement refuses at open with
`{:error, :chart_retirement_unsupported}`, naming the limit instead of
failing on a constraint. A host on another backend that wants the
capability alters those two columns in a migration of its own.

There is no clock here. Nothing retires on its own or on a schedule, no
call takes a duration, and when a chart should go is the host's policy.

On Postgres a retirement and the creates and migrations on its chart are
ordered by a per-chart advisory lock.
[What the chart lock reaches](docs/chart-lock.md) says what waits on what, why the
lock's key is scoped by the store and not by a tenant, the one way a
transaction of your own can deadlock on it, and what it means for test
suites running in parallel.

## Moving executions onto a newer chart

An execution stays on the chart it was created on. When a document is
edited and a new revision saved, an execution already waiting keeps its old
chart, and keeps that chart pinned, until you move it. Nothing moves one for
you: saving a chart, creating an execution and stepping one never migrate
anything. Three calls move executions when you ask:
`StatifierPersistence.Executions.migrate/4` moves one execution, and
`migrate_tree/4` moves a parent and the durable children it invoked
together. `migrate_batch/3` takes one plan and moves every `:active` and
`:needs_migration` execution on its `from` hash, one at a time rather than as
one unit: `migrate/4` for an unlinked execution and `migrate_tree/4` for a
linked one. `dry_run: true` previews it.

A library hold waits in `awaiting_pickup`. Entering that state scheduled the
pickup deadline as a delayed send, and started two invocations: a patron
notice (`<invoke id="notice">`) and a desk slip (`<invoke id="slip">`). The
next revision of the document renames the state `ready_for_pickup`. A
`Plan` says how a position crosses between the two charts; a state it does
not name maps to the state of the same id, so the plan names only the
rename:

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

The package stores no timer, so the pickup deadline stays in your queue with
its time unchanged, and the plan keeps it by mapping the state around it.
A plan that leaves such a state unmapped, or drops it, needs a
[pin source](#pin-sources) passed as `pin_sources:`, and without one the
call refuses with `{:no_pin_source, states}` before it reads the execution.
A source that counts a pending timer for an unmapped state refuses with a
`{:pending_timers, states, counts}` finding, so map the state around the
timer to keep it.
The `Plan` also has a string-keyed map form, `Plan.to_map/1` and
`Plan.from_map/1`, for a plan you store as JSON.

The migration is whole or it does not happen. Every check and the whole
transform come before the one write, and the write moves the execution to
the new hash at `:active`. `migrate/4` answers:

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

A refusal worth knowing is the one the patron notice shows. Suppose the
next revision also prints the desk slip first, so the two `<invoke>`
elements of `ready_for_pickup` come in the other order. An invocation keeps
its ordinal by default, the notice would land on the slip's element and
take that element's finalize and autoforward, and the rename plan above is
refused for both:

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
other finding and what a host does about each.

### Parking a refused execution

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
`needs_migration`, and `retire_chart/4` refuses while it waits. There are
two ways out:

- Correct the plan and call `migrate/4` again. A `:needs_migration`
  execution is migrated as an `:active` one is, and a success writes it
  back at `:active` on the plan's `to` chart.
- Decide it should go on unmigrated and call `Executions.unpark/3`, which
  puts it back to `:active` on the chart it was pinned to. Nothing is
  replayed; a delivery refused while it was parked is delivered again by you
  or not at all. An `:active` execution answers `{:ok, execution}` and
  nothing is written, and a terminal one answers `{:discarded, execution}`.

`fail/4` and `cancel/3` end a parked execution as they end an active one.

### Moving a tree

A durable child's linkage pins the child's own chart, so `migrate/4` moves
neither a child nor its pin. When the hold invoked a pickup-notice
execution as a durable child and both documents were edited,
`migrate_tree/4` moves the hold and its notice together, or neither:

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

`plans` maps an execution id to the plan for that node, and `machines:`
holds the `from` and `to` machine of every plan, by content hash. A node
you leave out of `plans` is not touched, and if it is live it must still
resolve against its parent as the parent will stand after the move. Every named node
is checked as `migrate/4` checks one, every refusal is collected before
anything is written, and the write is one unit, so the tree lands or none of
it does. The answers:

- `{:ok, moved}`: a `{execution, migrated}` pair per named node, children
  first and the root last.
- `{:error, {:tree_refused, refusals}}`: one or more nodes refused, keyed by
  execution id. A node's refusal is what `migrate/4` would answer for it, except
  `{:linked, _}`, which a tree never answers, or `{:machine_missing, hash}`,
  or `{:child_unresolved, parent_id, invoke_id}`.
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

## Pruning finished executions

A finished execution keeps its last position blob and, on an adapter that
keeps one, its whole input log. `StatifierPersistence.Retention.prune/3`
clears both for every execution that ended before a `DateTime` you pass,
in batches, and keeps the execution row: its status, answer and
`ended_at` stay, so the drained query still counts it and a parent can
still read a child's answer. As with retirement, the cutoff is your
policy and no call takes a duration.

[What a finished execution leaves behind](docs/retention.md) says what a
prune clears, which rows you may delete yourself and which you must not.

## Running the tests

The suite includes database-backed tests against a real Postgres server -
ADR-0005 rejects a skip tag for when one is absent, so `mix quality` and
`mix test` both need one reachable. Start it once with:

    docker compose up -d db

which brings up `postgres:17` on `localhost:5432` with user/password
`postgres`. Override host, port, user, password, or database name with the
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` env vars (see
`config/test.exs` for the defaults) if a server is already running
elsewhere.

## Surviving a restart

`docs/restart-demo.md` walks through the demo embedder that drives this
package's whole surface across a simulated restart with no Session
process: persist mid-execution with a pending durable timer and an in-flight
async invocation, drop everything volatile, cold-boot from the execution id
alone, and finish with zero duplicate side effects and a replay that
reproduces the path. The executable version lives in
`test/statifier_persistence/demo/restart_demo_test.exs` (and its
Postgres variant beside it).

## Scope

In scope:

- A storage-adapter behaviour: save/load of MachineState snapshots (or
  Recordings), guarded by the Machine identity so a position can never be
  loaded against the wrong chart.
- Execution lifecycle as a library: create/step/complete/fail, with a
  serialization guarantee per execution so concurrent event deliveries to one
  execution are ordered.
- The load -> handle_event -> execute effects -> persist loop, with effect
  execution delegated to the host.
- An Ecto adapter shipping schemas and migrations for chart definitions,
  versions, and executions; the host supplies the Repo and any tenancy columns.

Out of scope: domain actions, authoring UI, and job scheduling -
[statifier_oban](https://github.com/riddler/statifier_oban) owns timers and
async work.
