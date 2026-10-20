# StatifierPersistence

[![CI](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier_persistence/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_persistence.svg)](https://hex.pm/packages/statifier_persistence)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_persistence/)
[![License](https://img.shields.io/hexpm/l/statifier_persistence.svg)](https://github.com/riddler/statifier_persistence/blob/main/LICENSE)

Durable stepper and storage adapters for
[Statifier](https://github.com/riddler/statifier-ex). An execution of a chart
is a stored row rather than a live process: each event loads its position,
steps it, hands the effects to your host and persists the result, so a loan
that runs for weeks survives every restart and deploy in between.

> **Pre-1.0.** Until `statifier_persistence` reaches v1.0, its public surface may change
> between minor releases, sometimes drastically: a release may rename modules,
> callbacks, table columns, telemetry events or error vocabulary with no
> compatibility shim. Every such change is recorded in
> [CHANGELOG.md](CHANGELOG.md) under a bold **Breaking** heading that says what
> to do about it. Pinning to an exact minor - `~> X.Y.0` - is the recommended way
> to consume the package until 1.0. What a host changes for each minor from 0.13
> on is on one page:
> [`docs/upgrading.md`](docs/upgrading.md).

## Why a durable stepper

Statifier's pure interpreter contract (machine_state, event -> machine_state,
effects) makes a persistence-first execution model possible: load a persisted
position, step it, execute the effects, persist. Hosts running charts that
span days or survive deploys should not need long-lived Session processes at
all - but every host otherwise hand-rolls the loop, the storage guard, and the
crash semantics. This package is that loop, packaged: a storage-adapter
behaviour whose every load is guarded by the chart's identity, so a position
is never resumed against the wrong chart; an execution lifecycle that orders
concurrent deliveries to one execution; effects handed to your host through
one seam; and an Ecto adapter with versioned migrations, where your host
supplies the Repo and any tenancy columns. Domain actions, authoring UI and
job scheduling stay out of it:
[statifier_oban](https://github.com/riddler/statifier_oban) owns timers and
async work.

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

## Basic usage

A copy of a book lent to a patron is one execution, keyed by the loan. Store
the compiled chart, create the execution, and close the loan later from any
process with nothing but its id:

```elixir
alias Statifier.{Chart, Event}
alias StatifierPersistence.{Executions, Storage}

source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
  <state id="on_loan">
    <transition event="loan.due" target="due"/>
    <transition event="loan.returned" target="returned"/>
  </state>
  <state id="due">
    <transition event="loan.returned" target="returned"/>
  </state>
  <final id="returned"/>
</scxml>
"""

# Store the compiled chart once; every later load is checked against it.
{:ok, machine} = Statifier.compile(source)
{:ok, chart_blob} = Chart.to_binary(machine)
{:ok, store} = Storage.new(StatifierPersistence.Storage.InMemory, [])
:ok = Storage.save_chart(store, machine, chart_blob)

# Effects reach your host through one function; this chart emits none.
opts = [executor: fn _effect, _ctx -> :ok end]

{:ok, _execution, _state} = Executions.create(store, "loan_01H8", machine, opts)

# Later, in any process, with only the execution id:
{:ok, record} = Storage.fetch_execution(store, "loan_01H8")
{:ok, %{chart_blob: blob}} = Storage.fetch_chart(store, record.content_hash)
{:ok, machine} = Chart.from_binary(blob)

{:ok, execution, _state} =
  Executions.step(store, "loan_01H8", machine, Event.external("loan.returned"), opts)

execution.status
#=> :completed
```

The in-memory store keeps the example short; the Ecto adapter stores the same
rows in your database, and
[How to persist an execution and resume it in another process](docs/guides/persist-and-resume.md)
walks the whole loop with a chart that calls your host.

## Documentation

- Learn
  - [Basic usage](#basic-usage) - a loan stored as an execution and closed from another process with only its id
- Do
  - [How to set up the Ecto adapter](docs/guides/ecto-adapter.md) - configure a persistence module, migrate, build the guarded store, and run on a backend that is not Postgres
  - [How to persist an execution and resume it in another process](docs/guides/persist-and-resume.md) - store an execution after every step and carry it on from another process with only its id
  - [How to drive a chart that calls out](docs/guides/drive-a-chart.md) - run an execution whose chart invokes your host, and fan one invocation out over N children
  - [How to list executions by host scope and record inputs for replay](docs/guides/host-scope-and-inputs.md) - tag an execution with your own scope ids and list by them, and keep an input log so an execution can be replayed
  - [How to step inside a caller's transaction](docs/guides/caller-transaction.md) - write your own rows in the same transaction as a step, commit timer rows with the step's position, and deliver events while a step is in flight
  - [How to encrypt the blob columns and place host columns](docs/guides/encrypt-and-place-columns.md) - put an encrypting Ecto type on the payload columns, and put a column of your own at a fixed position in every table the migrations helper creates
  - [How to retire a chart and prune finished executions](docs/guides/retire-and-prune.md) - teach a retirement about state outside this package, retire a chart nothing can resume, and prune the position blobs and input logs of executions that have ended
  - [How to move executions onto a newer chart](docs/guides/move-executions.md) - move one execution, a parent with its durable children, or every execution on a chart onto the chart from a document's next revision, and park one the plan refuses
  - [How to run the Ecto adapter on a backend that is not Postgres](docs/non-postgres-backends.md) - decline the Postgres-only parts deliberately, and what declining costs
  - [How to run the test suite](docs/guides/running-the-tests.md) - start the Postgres server the suite needs, or point it at one you already run
  - [Upgrading a host](docs/upgrading.md) - what a host changes for each minor from 0.13 on
- Look up
  - [Cheatsheet](docs/reference/cheatsheet.cheatmd) - the calls to create, step and resume an execution, the Ecto adapter options, and retire and prune, on one page
  - [API reference](https://hexdocs.pm/statifier_persistence/api-reference.html) - every module, callback and option, from the moduledocs
  - [Telemetry and the OpenTelemetry bridge half](docs/telemetry.md) - what this package emits as a driver, the storage-phase contract, and what the bridge builds on them
  - [The changelog](CHANGELOG.md) - what changed in each version, with a **Breaking** heading for what a host must do
- Understand
  - [Documents, revisions, charts and executions, and why an execution is a durable row](docs/explanation/documents-revisions-charts-executions.md) - what the host keeps, what this package stores, and why an execution is a row that outlives every process
  - [Surviving a restart](docs/restart-demo.md) - a demo host persists mid-execution, drops everything volatile, cold-boots from the execution id alone and finishes with no duplicate side effects
  - [What a finished execution leaves behind](docs/retention.md) - what pruning clears, and which rows of an ended execution you may delete and which you must not
  - [What the chart lock reaches](docs/chart-lock.md) - what the per-chart lock between retiring a chart and putting an execution on it makes wait, and what its key is

## Compatibility

- Elixir `~> 1.18`.
- Statifier `~> 2.15`, `telemetry ~> 1.3` and `uxid ~> 2.0`.
- `ecto_sql ~> 3.10` is optional; with it the Ecto adapter is compiled. The
  adapter is written against Postgres, and runs on another Ecto backend with
  the Postgres-only parts declined
  ([How to run the Ecto adapter on a backend that is not Postgres](docs/non-postgres-backends.md)).
- Pre-1.0: pin an exact minor (`~> 0.25.0`) until 1.0, and read the
  [CHANGELOG](CHANGELOG.md)'s **Breaking** headings when you move it.
