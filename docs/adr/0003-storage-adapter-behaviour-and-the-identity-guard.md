# ADR-0003: Storage adapter behaviour and the identity guard

Status: accepted (2026-08-21) - amended 2026-08-21 (sp-5qa Phase 4: adds the
optional per-test isolation callback, `isolate/1`, to the behaviour's
contract surface, alongside the conformance suite decision 5 already names);
amended 2026-08-22 (sp-4an.2.1 Phase 5: adds the optional per-run lock
callback, `lock_run/3`, to the behaviour's contract surface, as the seam
ADR-0004 decision 5's default serialization strategy delegates to)

## Context

A persisted position is only meaningful against the exact chart revision
that produced it (st-ADR-0052, `deps/statifier/docs/persistence.md`).
Statifier's interned indices make a position silently wrong, not erroring,
against any other compilation of the chart - the hazard this repository's
own `CLAUDE.md` names as the reason "the identity guard is mandatory on
every load, never optional per adapter". Upstream already supplies a total
guard with typed refusal arms rather than leaving this package to invent
one:

- `deps/statifier/lib/statifier/machine/identity.ex:65-67` -
  `Identity.matches?/2` is total and answers `false` when either side is
  `nil`; two unidentified charts are never the same chart.
- `deps/statifier/lib/statifier/position.ex:136-179` - `Position.from_binary/2`
  runs an ordered check (safe decode, envelope tag, format version,
  identity, rebuild) and returns one of `{:error, :not_a_statifier_blob}`,
  `{:error, {:unsupported_format_version, version}}`,
  `{:error, {:identity_mismatch, expected, actual}}`, or
  `{:error, :unidentified_chart}`. Nothing raises.

ADR-0002's layering claim binds this record: "The storage-adapter behaviour
(sp-4an.1) speaks engine identities and opaque blobs, so key schemes and
table names never reach it." This ADR keeps that claim true by construction
rather than restating it - see Decision 3.

The vendored dependency this repository builds against
(`deps/statifier`, pinned in `mix.lock`) is ahead of the surface the bead's
research note described: `deps/statifier/lib/statifier/chart.ex` now exists
and `Statifier.Chart.to_binary/1` writes a
`{:statifier_chart, 1, identity, source, compile_opts}` envelope that
`Statifier.Chart.from_binary/1` recompiles back into a `Statifier.Machine.t()`.
Not every pin this package may run against carries that module, and a host
that retains its own SCXML source bytes satisfies the same contract without
it. This is why the chart record's payload is opaque here - see Decision 1.

## Decision

**1. The behaviour stores blobs, never positions.** Every data-bearing
`StatifierPersistence.Storage.Adapter` callback - `init/1`, `save_chart/2`,
`fetch_chart/2`, `save_position/2`, `fetch_position/2` - takes and returns
binaries plus engine identity strings. No callback receives a
`Statifier.Machine.t()` and none returns a `Statifier.MachineState.t()`. (The
optional `isolate/1` and `lock_run/3` this ADR's 2026-08-21 and 2026-08-22
amendments add are the exceptions, by design: neither carries chart or
position data at all - see the amendments under Decision 5.) The chart
record's
`chart_blob` is opaque to this layer: this record does not choose between
`Statifier.Chart.to_binary/1`'s envelope and a host's own retained source,
because both satisfy the only property the layer needs - given the blob
back, the host can reproduce the identified `Machine.t()`.

**2. The identity guard lives in the facade, above every adapter.**
`StatifierPersistence.Storage.load_position/3` is the only supported path
from a stored blob to a `Statifier.MachineState.t()`, and it delegates to
`Statifier.Position.from_binary/2`. An adapter cannot weaken, skip, or
configure the guard, because no adapter callback ever holds the two values
the guard compares (the stored identity and the caller's
`Statifier.Machine.t()`) at the same time. The guard is structural, not a
documentation promise an adapter author has to remember.

**3. Engine identities are the only keys this layer accepts.** A chart is
keyed by its content hash (`Statifier.Machine.Identity.content_hash`,
verbatim, per ADR-0002 decision 1); a position is keyed by the engine
session id (st-ADR-0008's `sess_` UXID), also verbatim. Both are opaque
strings to this layer. No callback signature accepts or returns a surrogate
key, a table name, or a prefix, which is what keeps ADR-0002's layering
claim literally true rather than merely asserted.

**4. The error vocabulary surfaces upstream's arms unflattened and adds
three of this package's own.** `Statifier.Position.from_binary/2`'s four
arms - `:not_a_statifier_blob`, `{:unsupported_format_version, version}`,
`{:identity_mismatch, expected, actual}`, `:unidentified_chart` - reach the
facade's caller exactly as upstream produced them; `identity_mismatch`
carries both identities because the caller's next move (drain the old
revision, or migrate the position) depends on knowing which revision it
has. This package adds `:chart_not_found`, `:position_not_found`, and
`{:adapter, term()}` for a backend failure. Nothing is rescued to a default
and nothing raises; no arm is collapsed into another.

**5. The conformance suite ships in `lib/`, under
`StatifierPersistence.Testing.*`.** `StatifierPersistence.Testing.StorageConformance`
follows the precedent `deps/statifier/lib/statifier/testing/case.ex` sets
under st-ADR-0053: a test-case template that lives in `lib/` so a
downstream adapter (the Ecto adapter, sp-4an.3) can `use` it outside this
repository's own `test/`. The same one-way rule applies: no module in
`lib/` outside the `StatifierPersistence.Testing.*` namespace may reference
anything inside it.

*(Amended 2026-08-21, sp-5qa Phase 4: the conformance suite's `setup` calls
an optional callback, `c:StatifierPersistence.Storage.Adapter.isolate/1`,
right after `init/1`, when the adapter under test exports it. It exists for
an adapter backed by a shared resource - a database connection, a sandbox
checkout - to wrap the test that follows in its own isolated unit (an
`Ecto.Adapters.SQL.Sandbox` checkout, for one), so the conformance suite's
tests do not leak state into each other through that resource. It is
declared `@optional_callbacks` on `StatifierPersistence.Storage.Adapter`
with no default implementation in the behaviour itself; the template's own
`function_exported?/3` check is the no-op default, so an adapter needing no
isolation - `StatifierPersistence.Storage.InMemory` among them - simply does
not implement it. This widens the behaviour's contract surface, which is why
it is recorded here rather than left as an undocumented convention the
template alone establishes; decision 5's shape - test-side surface shipped
in `lib/` for a downstream adapter to reuse - is what makes the hook
possible in the first place, so it belongs with that decision rather than as
a new one.)*

*(Amended 2026-08-22, sp-4an.2.1 Phase 5: the behaviour gains a second
optional callback, `c:StatifierPersistence.Storage.Adapter.lock_run/3` -
mutual exclusion per `run_id`, running the given fun while the exclusion is
held and releasing it on any exit, a raise escaping the fun included, so
the lock cannot leak. It is the seam ADR-0004 decision 5's default
serialization strategy (`StatifierPersistence.Serialization.AdapterLock`)
delegates to, and the strategy refuses with
`{:error, {:serialization, :not_supported}}` when an adapter does not
export it; an Ecto adapter implements it as a transaction-scoped row lock
(sp-4an.3). Like `isolate/1` it is declared `@optional_callbacks` with no
default implementation, carries no chart or position data, and decodes
nothing, so decision 1's blobs-only rule holds; the conformance suite
exercises it only when the adapter under test exports it, the same
`function_exported?/3` shape the isolate amendment records - which is why
this widening, like that one, is recorded here with decision 5 rather than
as a new decision.)*

## Consequences

- An adapter author has no code path in which to be careless about the
  guard: nothing in the behaviour can decode a position, so there is
  nothing to forget to check.
- What would reopen this record: a load path that needs an adapter to hold
  both a `Statifier.Machine.t()` and a stored blob at once; a second
  adapter that cannot satisfy a callback as specified; an upstream change
  to the position envelope or to `Identity.matches?/2`; or the behaviour
  (sp-4an.1) ever needing to see a surrogate key or table name, which is
  the failure ADR-0002's layering claim is written to catch.
- `delete_position` and any optimistic-concurrency or revision-counter
  behavior on `save_position` are deliberately not part of this contract.
  Both belong with the run lifecycle and locking decisions in sp-4an.2; an
  unexercised callback here would be an unverified contract every future
  adapter still has to satisfy.
- This record does not choose between `Statifier.Chart.to_binary/1` and a
  host-retained SCXML source for `chart_blob`, and does not need to: the
  guard, the keys, and the error vocabulary above hold regardless of which
  a host picks.
