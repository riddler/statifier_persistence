# Running the Ecto adapter on a backend that is not Postgres

`StatifierPersistence.Storage.Ecto` is written against Postgres, and this
package's own gate runs against a real Postgres server (ADR-0005 decision
2). That is not the same as the adapter being unusable elsewhere: most of
it is ordinary Ecto, and a host on SQLite, MySQL, or anything else with an
Ecto adapter can run the whole persisted-position loop on it - by
declining the parts that are Postgres-only, deliberately and in writing,
rather than discovering them at the far end of a run.

This guide is that opt-out: what is Postgres-only, how to decline it, what
declining costs, and how to prove your own setup is honest about it.

## What is Postgres-only

Three callbacks on the Ecto adapter are Postgres SQL, and one migration
step is a Postgres index.

| Surface | Why | What happens elsewhere |
|---|---|---|
| `lock_run/3` | `SELECT pg_advisory_xact_lock(hashtextextended(...))` plus `FOR UPDATE` | The backend does not parse it. The callback raises |
| `list_runs_by_metadata/2`, `list_run_states_by_metadata/2` | `jsonb` containment (`@>`) with a `-> ... ->>` extraction | The backend does not parse it. Called directly, the callbacks raise |
| `supports_metadata?/1` | Declares the `jsonb` column *and* the list helpers as one capability | Already answers `false` off `repo.__adapter__()`, so `StatifierPersistence.Storage` refuses the listings cleanly rather than reaching the raising SQL |
| V03's `GIN jsonb_path_ops` index on `runs.metadata` | Serves the containment query above | The migration helper skips it, so `Migrations.up/1` runs to completion and the `outcome_blob` column arrives |

The last two rows are already engine-conditional and need nothing from
you. Everything a host has to decide is about the first row.

The run metadata *column* is not Postgres-only, and neither is anything
else in the loop: charts, positions, run records, the identity guard, the
executor seam, effects, resume, and the versioned migrations all work on
any Ecto backend.

## Declining the lock callback

Per-run ordering is a strategy, not a hardcoded lock
(`StatifierPersistence.Serialization`, ADR-0004 decision 5). The default
is `{StatifierPersistence.Serialization.AdapterLock, store}`, which
delegates to the adapter's `lock_run/3` - the Postgres SQL above. On
another backend, pass your own strategy instead, on every
`StatifierPersistence.Runs` call and on `StatifierPersistence.Driver.new/3`:

```elixir
defmodule MyApp.RunLock do
  @behaviour StatifierPersistence.Serialization

  @impl StatifierPersistence.Serialization
  def with_run(_config, run_id, fun) do
    MyApp.SingleWriter.exclusively(run_id, fun)
  end
end

driver =
  StatifierPersistence.Driver.new(store, machine,
    dispatch: &MyApp.perform/3,
    serialization: {MyApp.RunLock, nil}
  )
```

There are two honest shapes for that strategy:

1. **A real exclusion the host already owns.** A job queue with a per-run
   unique key, a single consumer per run id, a distributed lock service, a
   `GenServer` registry keyed by run id in a single-node deployment. The
   guarantee the behaviour asks for is documented on
   `c:StatifierPersistence.Serialization.with_run/3`: for one `run_id`, two
   bodies never overlap, and a body that finishes before another starts is
   durable before the later one loads.

2. **A pass-through, plus a single writer by construction.** `fn _c, _id,
   fun -> {:ok, fun.()} end` provides no exclusion at all. It is correct
   only when nothing in your deployment can deliver two events to one run
   concurrently - one node, one worker, no retries that can overlap a live
   delivery.

What you must not do is keep the default. `AdapterLock` on a non-Postgres
repo does not refuse; it reaches `lock_run/3` and raises, mid-run, after
effects may already have gone out.

## What declining costs

Serialization is what makes the fetch-to-persist tail atomic per run. With
a pass-through, two concurrent deliveries to one run both load the same
position, both step it, and both persist: the second write wins and the
first event's work is silently lost, while its effects have already been
delivered. That is the failure mode, and it is not detectable after the
fact from the stored position.

So the pass-through arm is for **single-writer hosts only**, and "single
writer" has to be a property of the deployment, not a hope about timing.
If you cannot name the mechanism that makes it true, you need shape 1.

Two further things a non-Postgres backend does not get, both of which
refuse rather than break:

- **Durable subcharts and fan-out** (ADR-0008). Starting a child run needs
  the metadata listing to find children again, so `Storage` refuses at
  open with `{:refused, :child_listing_unsupported}`. No child is started
  and no half-open parent is left behind.
- **Listing runs by host scope.** `Storage.list_runs_by_metadata/2` answers
  `{:error, :child_listing_unsupported}` and
  `Storage.list_run_states_by_metadata/2` answers
  `{:error, :run_states_unsupported}`. Query your own column directly
  instead; ADR-0002's configurable table names make that a supported thing
  to do.

## How to verify

Point the shipped conformance suite at the adapter over your own host
module, and exclude the Postgres-only cases by tag:

```elixir
defmodule MyApp.SqliteConformanceTest do
  use StatifierPersistence.Testing.StorageConformance,
    async: false,
    adapter: StatifierPersistence.Storage.Ecto,
    opts: [persistence: MyApp.Persistence]
end
```

```
mix test test/my_app/sqlite_conformance_test.exs --exclude postgres
```

Four cases carry `@tag :postgres` - the two `lock_run/3` cases and the two
metadata-listing cases - and nothing else in the suite does. A correct run
therefore reports every other case passing and exactly those four
excluded:

```
31 tests, 0 failures, 4 excluded
```

Run it once **without** `--exclude postgres` as well, and read the
failures. Four failures, all four of them the tagged cases, is the proof
that the tag is excluding what it claims to and not covering for something
else. Any fifth failure is a real portability problem in your setup, and
the exclusion would have hidden it.

Two things this does not prove, and should not be read as proving. It does
not prove the lock contract on your backend - you declined that callback,
which is the point. And it does not make the excluded run a substitute for
this package's own gate: ADR-0005 decision 2 stands, and every storage,
conformance and lock case here still runs against a real Postgres server.

## Where this is recorded

- `docs/adr/0005-ecto-in-package-and-postgres-test-harness.md`, decision 2
  and its 2026-09-06 Note: why the harness is Postgres, and what that does
  and does not claim about who runs SQLite.
- `docs/adr/0004-run-lifecycle-executor-seam-and-serialization.md`,
  decision 5: the serialization strategy as a seam, and the Ecto adapter's
  lock as one implementation of it.
- `docs/adr/0006-optional-opaque-run-metadata.md`, decision 3: metadata
  support as a declared capability, with refusal at open as the arm an
  adapter that cannot store it takes.
- `test/statifier_persistence/ecto/sqlite_migrations_test.exs`: the
  standing proof, on a real SQLite repo, that V03 applies, that the index
  is skipped, and that what the index served refuses rather than raises.
