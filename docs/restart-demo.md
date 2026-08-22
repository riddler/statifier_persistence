# Surviving a restart: the demo host

`test/statifier_persistence/demo/` is a demo embedder that runs a
multi-step chart across a simulated restart with no `Statifier.Session`
process at all: persist mid-run, drop every volatile process and struct,
cold-boot from the run id alone, continue, finish. It exists to validate
this package's whole surface - the identity guard (ADR-0003), the run
lifecycle and executor seam (ADR-0004), and both storage adapters - the
way the charter demands: driven by an embedder-shaped pipeline, not by
unit tests alone.

Every claim below is asserted by a test; when the prose and the tests
disagree, the tests win.

- `test/statifier_persistence/demo/restart_demo_test.exs` - the scenario
  over `Storage.InMemory`, with the full per-stage assertions.
- `test/statifier_persistence/demo/restart_demo_ecto_test.exs` - the same
  scenario bodies over `Storage.Ecto` and real Postgres.
- `test/support/demo/` - the host the tests drive: `Host`, `Ledger`,
  `Runtime`, `EnrichHandler`, `Scenario`.

## The chart and the kill point

The chart (`test/support/demo/scenario.ex`) walks
`intake -> enriching -> cooling -> settling -> settled`, with an
`escalated` state as the negative target - reaching it means the host
lost a race it exists to control, and the tests assert it is never
entered.

The kill point is `enriching`, chosen so the restart happens with the
maximum in flight:

- a **pending durable timer** - `enriching`'s onentry armed a 900s
  `sla-timer`;
- an **in-flight async invocation** - the `myapp:enrich` invoke started a
  real worker process.

At that moment the volatile runtime is stopped - every worker pid and
armed in-memory timer dies with it - and a fresh host is booted from
nothing but the run id.

## What survives, and what the host must rebuild

| Piece | Lives in | Survives the restart |
|---|---|---|
| the run's position and status | `StatifierPersistence.Storage` (InMemory / Postgres) | yes |
| the chart blob | `StatifierPersistence.Storage` | yes |
| the host's own timer and invocation rows | `Demo.Ledger` (stands in for the embedder's tables) | yes |
| armed timers, live worker pids | `Demo.Runtime` (supervisor over volatile state) | no - stopped and rebuilt |
| the `%Host{}` struct | plain struct | no - rebuilt by `boot/4` |
| the compiled `%Machine{}` | recompiled from the stored chart blob | no - `Chart.from_binary/1` on boot |
| the handler palette (`invoke_types`, `invoke_handlers`) | per-deployment declaration | no - re-supplied on every step (st-ADR-0064) |

st-ADR-0060's rule is "resume restores position, not liveness", and the
demo makes each half of that visible:

1. **Position restores.** `boot/4` re-reads the run record and the chart
   blob, recompiles a freshly interned machine, and the next step's
   identity guard proves the pair still match. The restart tests assert
   the boot really re-read stored bytes rather than reusing a carried
   struct.
2. **Timers do not.** Nothing about a pending delayed send survives in
   the position - `delay_ms` is relative and no wall-clock instant is
   stored. `recover/1` re-arms every open timer from the host's own
   durable rows; the `sla-timer` that fires after the restart was armed
   before it, and fires from that durable row.
3. **Invocations do not.** The position's `active_invocations` records
   *what was invoked*, never a pid. `recover/1` re-establishes each
   invocation the engine still considers active and the ledger still
   shows open, by re-running the ADR-0051 handler's `start/2` - the
   engine is the liveness authority, the host's rows are the payload
   source. The tests assert the post-restart worker is a live pid
   different from the dead pre-restart one.
4. **Nothing runs twice.** Re-arming and re-establishing are idempotent
   on their durable keys (`{run_id, ordinal}` for timers, `invoke_id`
   for invocations), and recovery goes through the host's own hands, not
   back through the executor seam - so the executor call log after the
   restarted run is exactly the straight-through run's, asserted on
   exact contents.
5. **The inputs are the host's to record.** `boot/4` restores no input
   tape; the recorder carries it. A replay of the recorded events -
   plus the one generated create input, the session id - against a
   fresh store reproduces the identical configuration sequence and the
   identical effect structs, field for field.

## Where every effect goes

Nothing the host does to the outside world happens outside the
`StatifierPersistence.Executor` seam: one arity-2 fun
(`Demo.Host.executor/1`) receives every effect, records it, and
dispatches it - durable row first, volatile arm/spawn second. The two
deliberate exceptions are cold-boot obligations, not chart effects:
`boot/4`'s chart-fetched marker and `recover/1`'s re-establishment,
both of which exist precisely because no step emits them.

## The boundary

The durable timer store here is the *host's own* (`Demo.Ledger`), and
the mock clock is the demo's one departure from a production host - the
gate must stay fast and deterministic. A production embedder hands the
same `SendDelayed`/`Cancel` effects to a real scheduler instead; that is
statifier_oban's charter (st-ADR-0054). The seam is identical either
way, which is the point: this package stops at the effect vocabulary,
and everything the demo rebuilds by hand is exactly the work a durable
scheduler package takes on.
