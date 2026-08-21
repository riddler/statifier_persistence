# ADR-0003: Storage adapter behaviour and the identity guard

Status: accepted (2026-08-21)

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

**1. The behaviour stores blobs, never positions.** Every
`StatifierPersistence.Storage.Adapter` callback takes and returns binaries
plus engine identity strings. No callback receives a `Statifier.Machine.t()`
and none returns a `Statifier.MachineState.t()`. The chart record's
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
