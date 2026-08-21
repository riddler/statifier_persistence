# Storage behaviour and identity guard Implementation Plan

## Overview

Define this package's first contract surface: a storage-adapter behaviour that
persists and retrieves opaque engine blobs keyed by engine identities, a
guarded load path that refuses a chart-revision mismatch as a typed error, an
in-memory reference adapter, and a conformance case template the Ecto adapter
(sp-4an.3) reuses unchanged. Bead: sp-5qa.

## Current State Analysis

The repository is a scaffold. `lib/` holds only `lib/statifier_persistence.ex`
(a `version/0` function), `test/` holds only
`test/statifier_persistence_test.exs`. Nothing in this package implements or
consumes the engine contract yet, so every convention below is inherited from
statifier-ex rather than demonstrated here.

Two ADRs are accepted and bound this work:

- `docs/adr/0001-record-architecture-decisions.md` - three sections (Context,
  Decision, Consequences), numbered sequentially, indexed in
  `docs/adr/README.md`. A bare `ADR-NNNN` is this repo's own; a cross-repo
  citation carries the owning prefix (`st-ADR-0052`). The bar for writing one
  is "the decision changes what a host reads - the behaviour's contract
  surface" - which is exactly this bead.
- `docs/adr/0002-configurable-keys-and-table-names.md` - decision 1: engine
  identities are stored verbatim and are not configurable. And its layering
  claim, stated as a fact this plan must keep true: "The storage-adapter
  behaviour (sp-4an.1) speaks engine identities and opaque blobs, so key
  schemes and table names never reach it." ADR-0002's Consequences names the
  behaviour ever needing to see a surrogate key or table name as the thing
  that would reopen that record.

The engine surface is vendored at `deps/statifier/` and was read directly
rather than taken on trust:

- `deps/statifier/lib/statifier/machine/identity.ex:39-70` -
  `Identity.of_source/2` produces
  `%Identity{content_hash: "sha256:" <> lowercase_hex, name: nil, version: nil}`;
  `Identity.matches?/2` is total and answers `false` when either side is
  `nil`. `to_binary/1` / `from_binary/1` (lines 78-110) are the
  `{:statifier_chart_identity, 1, identity}` envelope, with
  `:not_a_statifier_blob` and `{:unsupported_format_version, v}` arms.
- `deps/statifier/lib/statifier/position.ex:88-160` - `to_binary/1` returns
  `{:ok, binary} | {:error, :unidentified_chart}`; `from_binary/2` checks, in
  order, safe decode -> envelope tag -> format version -> identity -> rebuild,
  with arms `:not_a_statifier_blob`, `{:unsupported_format_version, v}`,
  `{:identity_mismatch, expected, actual}`, `:unidentified_chart`.
  `Position.format_version/0` is `2` on this pin, and a version-1 blob is
  read, not refused.
- `deps/statifier/lib/statifier.ex:101` -
  `Statifier.compile(source, opts) :: {:ok, Machine.t()} | {:error, [error()]}`.
- `deps/statifier/lib/statifier/machine.ex:387` -
  `Machine.identity/1 :: Identity.t() | nil`.

### Drift found against the bead's research note

The bead's 2026-08-21 note was verified against statifier-ex `1ad889a`. The
vendored dep this worktree builds against is `0c557068` (`mix.lock:18`), and
it is ahead: `deps/statifier/lib/statifier/chart.ex` now exists.
`Statifier.Chart.to_binary/1` writes
`{:statifier_chart, 1, identity, source, compile_opts}` and
`Statifier.Chart.from_binary/1` recompiles a `Machine.t()` from it, with arms
`:not_a_statifier_blob`, `{:unsupported_format_version, v}`,
`{:compile_failed, errors}`, `{:identity_mismatch, expected, actual}`.
`deps/statifier/docs/persistence.md` presents the two-line reload recipe:

```elixir
{:ok, machine} = Statifier.Chart.from_binary(chart_blob)
{:ok, machine_state} = Statifier.Position.from_binary(position_blob, machine)
```

This does not invalidate the note - it adds a mechanized form of the note's
item 1 ("the SCXML source text"). This plan resolves it by storing an opaque
`chart_blob` binary and refusing to say what produced it; see Implementation
Approach.

## Desired End State

After this plan, the package exposes three public modules and one test-side
module, and a host can persist and reload a position through any adapter with
the guard applied whether the adapter author remembered it or not:

- `StatifierPersistence.Storage.Adapter` - the behaviour. Blob-level
  `@callback`s only, each with `@doc` prose stating what it must and must not
  do. No callback performs an identity check, and none can be handed a
  surrogate key or a table name.
- `StatifierPersistence.Storage` - the guarded facade and the only supported
  way to turn a stored position blob back into a
  `Statifier.MachineState.t()`. Carries a `%StatifierPersistence.Storage{}`
  handle as its first argument (project convention: the state comes first).
- `StatifierPersistence.Storage.InMemory` - the reference adapter, Agent
  backed, shipped in `lib/` because the conformance suite and downstream
  adapter authors both need it outside `test/`.
- `StatifierPersistence.Testing.StorageConformance` - an
  `ExUnit.CaseTemplate` in `lib/`, following st-ADR-0053's precedent
  (`deps/statifier/lib/statifier/testing/case.ex`), so sp-4an.3's Ecto
  adapter runs the identical suite with `use
  StatifierPersistence.Testing.StorageConformance, adapter: ..., opts: ...`.

Verification that the end state holds: `mix quality` green with coverage at
or above the 90% floor `coveralls.json` sets; the conformance suite green
against `InMemory`; and `ADR-0003` present and indexed in
`docs/adr/README.md`.

### Key Discoveries:

- `deps/statifier/lib/statifier/position.ex:139-160` - the guard's typed arms
  already exist upstream and are total. This package's job is to route them
  out unwrapped, not to invent an error vocabulary.
- `deps/statifier/lib/statifier/machine/identity.ex:62-66` -
  `matches?/2` answers `false` for `nil` on either side. Two unidentified
  charts are not the same chart. Any cheap pre-check this package adds must
  use `matches?/2`, never `==/2` (st-ADR-0052 decision 1).
- `deps/statifier/lib/statifier/testing/case.ex:1-12` - upstream's precedent
  for shipping a test case template in `lib/` under a `Testing.*` namespace,
  with the rule that no module in `lib/` outside that namespace may reference
  anything inside it (st-ADR-0053). This plan adopts the same rule.
- `docs/adr/0002-configurable-keys-and-table-names.md` decision 1 and its
  Consequences - engine identities verbatim, and the behaviour never seeing a
  surrogate key. This plan's callbacks take a content hash and an engine
  session id and nothing else that identifies a row.
- `coveralls.json` sets `minimum_coverage: 90` and skips only `test/support/`.
  Every phase that adds executable `lib/` code must land tests in the same
  phase or the full gate goes red on coverage. That is what fixes the phase
  boundaries below.
- `.quality.exs` - the loop profile runs format, compile, credo, and changed
  tests; the full gate adds dialyzer, deps audit, and coverage. Credo runs
  `--strict` with its own defaults, so every public function needs a `@doc`
  and the moduledocs must be real.

## What We're NOT Doing

- **`Statifier.Position.export/1` / `import/2`.** The cross-revision migration
  pair deliberately skips the identity check
  (`deps/statifier/lib/statifier/position.ex:36-52`). Exposing it through a
  storage API whose entire premise is a mandatory guard would be the wrong
  place for it; it is a separate story with its own operator-facing shape.
- **Re-stamping `routes` and `invoke_types`.** `Position.from_binary/2`
  returns both `nil` by design; re-stamping is the stepper's job in sp-4an.2.
  The facade returns the `MachineState` exactly as `from_binary/2` produced
  it and documents that the two fields are the caller's to fill.
- **Timers and durable scheduling.** statifier_oban's contract, per this
  repo's `CLAUDE.md` and st-ADR-0054.
- **Ecto, schemas, migrations, key generators, table names.** sp-4an.3 owns
  all of it under ADR-0002. Nothing in this plan adds a dep.
- **The run lifecycle** (`create/step/complete/fail`) and locking. sp-4an.2.
  This bead stops at save/load of blobs keyed by engine identities.
- **A `delete_position` callback.** A durable stepper will eventually want
  one, but nothing in this bead exercises it, and an unexercised callback is
  an unverified contract every future adapter still has to satisfy. It is
  added when the lifecycle work needs it.
- **Optimistic-concurrency or revision counters on `save_position`.** Same
  reason: concurrency semantics belong with the locking decision in
  sp-4an.2, and guessing them now would ship a callback signature that
  record then has to break.
- **Persisting a `Statifier.Session.Recording.t()`.** It is the third
  persistable artifact upstream names, and nothing in the charter's
  load -> step -> execute -> persist loop reads one.

## Implementation Approach

Four ideas carry the design, and the ADR in Phase 1 records all four.

**1. The guard is structural, not a callback.** An adapter that could
implement the guard could also forget it, and "mandatory on every load, never
optional per adapter" would then be a documentation promise rather than a
fact. So adapters store and return **binaries only**. Nothing in the
behaviour returns a `Statifier.MachineState.t()`, and nothing in it takes a
`Statifier.Machine.t()`. The only code in this package that turns a stored
blob into a position is `StatifierPersistence.Storage.load_position/3`, and
it calls `Statifier.Position.from_binary/2`, which cannot be asked to skip
the check. An adapter author has no code path in which to be careless.

**2. The behaviour speaks engine identities and opaque blobs.** Charts are
keyed by `content_hash` (`Identity.content_hash`, verbatim, per ADR-0002
decision 1). Positions are keyed by the engine session id (st-ADR-0008's
`sess_` UXID), also verbatim. Both are opaque strings to this layer; no
surrogate key, table name, or prefix appears in any signature, keeping
ADR-0002's layering claim literally true.

**3. The chart record carries an opaque `chart_blob`, and this package does
not say what produced it.** The drift noted above gives a host two honest
options - `Statifier.Chart.to_binary/1`'s single envelope, or its own
retained SCXML source bytes - and both satisfy the only property this layer
needs: given the blob back, the host can reproduce the identified
`Machine.t()`. Storing the bytes opaquely means this package neither depends
on `Statifier.Chart` (which does not exist on every pin the bead's research
saw) nor forbids it. The `identity_blob` column
(`Identity.to_binary/1`) is stored beside it exactly as
`deps/statifier/docs/persistence.md`'s item 2 prescribes, so a host can ask
which revision a stored chart is without paying a recompile.

**4. Errors are events, and upstream's arms are surfaced unflattened.** The
facade's error type is upstream's four position arms plus this package's own
two not-found arms plus `{:adapter, term()}` for a backend failure an Ecto
adapter will need. Nothing is rescued to a default and nothing raises;
`{:identity_mismatch, expected, actual}` in particular reaches the caller
with both identities intact, because the caller's next move (drain the old
revision, or migrate the position) depends on knowing which revision it has.

Phase ordering follows the coverage floor: the ADR lands first (docs only,
trivially green), then each code phase lands its own tests so no intermediate
commit drops coverage below 90.

## Phase 1: Record the contract surface as ADR-0003

### Overview

Write the decision record before the code that encodes it, per ADR-0001's own
Consequences. Docs only, so it is independently committable and the gate is
green by construction.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`
**Changes**: New file. Three sections, Context / Decision / Consequences, per
ADR-0001. House style for this directory is plain ASCII punctuation with
spaced hyphens - match `0001` and `0002` exactly, and do not introduce
typographic dashes.

Content the record must contain:

- **Context**: the interned-index hazard restated by reference, not
  re-argued (`st-ADR-0052`, `deps/statifier/docs/persistence.md`); the fact
  that upstream already supplies a total guard with typed arms; ADR-0002's
  layering claim that this layer sees no surrogate keys; and the note that
  upstream's `Statifier.Chart` envelope postdates some pins, which is why
  the chart bytes are opaque here.
- **Decision 1 - the behaviour stores blobs, never positions.** Callbacks
  take and return binaries plus engine identity strings. No callback
  receives a `Statifier.Machine.t()` and none returns a
  `Statifier.MachineState.t()`.
- **Decision 2 - the identity guard lives in the facade, above every
  adapter.** `StatifierPersistence.Storage.load_position/3` is the only
  supported decode path, and it delegates to
  `Statifier.Position.from_binary/2`. An adapter cannot weaken, skip, or
  configure the guard, because it never holds the two values the guard
  compares at the same time.
- **Decision 3 - engine identities are the only keys at this layer**: chart
  content hash and engine session id, verbatim, adopting ADR-0002 decision 1
  by reference.
- **Decision 4 - the error vocabulary.** Upstream's arms
  (`:not_a_statifier_blob`, `{:unsupported_format_version, v}`,
  `{:identity_mismatch, expected, actual}`, `:unidentified_chart`) are
  surfaced unflattened; this package adds `:chart_not_found`,
  `:position_not_found`, and `{:adapter, term()}`. Nothing raises, and no
  arm is collapsed into another.
- **Decision 5 - the conformance suite ships in `lib/` under
  `StatifierPersistence.Testing.*`**, adopting st-ADR-0053's shape, with the
  same one-way rule: no module in `lib/` outside that namespace may
  reference anything inside it.
- **Consequences**: what reopens the record (a load path that needs the
  adapter to hold both the machine and the blob; a second adapter that
  cannot satisfy a callback; an upstream change to the position envelope or
  to `Identity.matches?/2`); the deliberate omission of `delete_position`
  and of concurrency semantics, both deferred to sp-4an.2; and the note that
  this record does not choose between `Statifier.Chart.to_binary/1` and
  host-retained source.

#### 2. The index

**File**: `docs/adr/README.md`
**Changes**: Add the 0003 row to the table, matching the existing two rows'
column style.

```
| [0003](0003-storage-adapter-behaviour-and-the-identity-guard.md) | The storage adapter stores opaque blobs keyed by engine identities; the identity guard lives above every adapter and cannot be skipped | accepted |
```

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`).
- [x] `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`
      exists and contains the headings `## Context`, `## Decision`, and
      `## Consequences`.
- [x] `docs/adr/README.md` contains a link to the 0003 file.
- [x] The ADR and the README row contain no em dash, en dash, or curly quote
      (`grep -nP '[\x{2010}-\x{2015}\x{2018}\x{2019}\x{201C}\x{201D}]'`
      returns nothing for both files).
- [x] The terminology scan from the umbrella's
      `docs/terminology-firewall.md` finds nothing in the diff.

#### Manual Verification:
- [ ] The record reads as a decision, not a design sketch: someone citing
      "ADR-0003 decision 2" ends the argument about where the guard lives.
- [ ] Nothing in it contradicts ADR-0001 or ADR-0002, and the ADR-0002
      layering claim is adopted by reference rather than restated in a way
      that could drift.
- [ ] The cross-repo citations use the `st-ADR-NNNN` form and the bare
      `ADR-NNNN` form is only ever this repo's own.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: The adapter behaviour and the in-memory reference adapter

### Overview

Land the `@callback` surface and one implementation of it, with direct unit
tests, so the phase is green on its own and coverage does not dip. No guard
yet - this phase deliberately ships only the blob layer, which is what makes
decision 1 checkable: nothing here can decode a position.

### Changes Required:

#### 1. The behaviour

**File**: `lib/statifier_persistence/storage/adapter.ex`
**Changes**: New module. Types, five callbacks, `@doc` prose on each stating
the contract and the refusal arms.

```elixir
defmodule StatifierPersistence.Storage.Adapter do
  @moduledoc """
  The storage contract: opaque blobs keyed by engine identities.
  ... (ADR-0003 decisions 1 and 3 restated for an adapter author)
  """

  @typedoc "Adapter configuration, opaque to this package."
  @type opts :: keyword()

  @typedoc "A chart's content hash, verbatim from `Statifier.Machine.Identity` (ADR-0002 decision 1)."
  @type content_hash :: String.t()

  @typedoc "An engine session id (st-ADR-0008), verbatim."
  @type session_id :: String.t()

  @type chart_record :: %{
          content_hash: content_hash(),
          identity_blob: binary(),
          chart_blob: binary()
        }

  @type position_record :: %{
          session_id: session_id(),
          content_hash: content_hash(),
          identity_blob: binary(),
          position_blob: binary()
        }

  @type error ::
          :chart_not_found
          | :position_not_found
          | {:adapter, term()}

  @callback init(opts()) :: {:ok, opts()} | {:error, error()}
  @callback save_chart(opts(), chart_record()) :: :ok | {:error, error()}
  @callback fetch_chart(opts(), content_hash()) :: {:ok, chart_record()} | {:error, error()}
  @callback save_position(opts(), position_record()) :: :ok | {:error, error()}
  @callback fetch_position(opts(), session_id()) :: {:ok, position_record()} | {:error, error()}
end
```

Contract prose the `@doc`s must state, because the conformance suite asserts
it and an adapter author cannot infer it:

- `save_chart/2` is idempotent on `content_hash`: saving the same hash twice
  is `:ok` and does not duplicate. A hash is a content address, so a second
  write of the same hash is by definition the same chart.
- `save_position/2` overwrites the position for a `session_id`. A session has
  exactly one current position; history is not this layer's concern.
- `fetch_chart/2` and `fetch_position/2` return `:chart_not_found` /
  `:position_not_found` rather than raising or returning `nil`.
- No callback inspects, decodes, or validates a blob's bytes. Refusing a blob
  on content is the facade's job, and an adapter that decodes one has
  overreached.
- No callback performs an identity check. The `content_hash` and
  `identity_blob` on a `position_record` are stored so a host can index by
  revision without a decode; they are not the guard.

**Note on `init/1`**: it exists so an adapter that needs setup (starting an
Agent, checking a repo is reachable) has a declared place for it, and so the
facade has one call to make when a handle is built. An adapter needing none
returns `{:ok, opts}`.

#### 2. The in-memory reference adapter

**File**: `lib/statifier_persistence/storage/in_memory.ex`
**Changes**: New module. `@behaviour StatifierPersistence.Storage.Adapter`,
Agent backed, two maps in its state (`charts` keyed by content hash,
`positions` keyed by session id). `init/1` starts the Agent and returns the
opts with the pid or name merged in, so the returned opts are the handle.

It ships in `lib/`, not `test/support/`, for two reasons the moduledoc should
state: the conformance template in `lib/` needs a reference implementation to
be checked against outside this repo's `test/`, and a host prototyping the
stepper wants an adapter with no database.

#### 3. Unit tests

**File**: `test/statifier_persistence/storage/in_memory_test.exs`
**Changes**: New. Direct tests of round-tripping a chart and a position,
idempotent `save_chart/2`, overwriting `save_position/2`, and both not-found
arms. Pattern matching over multiple asserts, per the project convention.

These are deliberately narrow: the broad behavioural suite arrives in Phase 4
and supersedes the overlap, which Phase 4 then deletes rather than leaving as
a second copy.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`), including dialyzer and the
      90% coverage floor.
- [ ] Every new test that asserts `lib/` behavior has been sabotage-verified:
      break the covered code, confirm the test goes red, revert, and leave a
      one-line `# sabotage: ...` note above the test, as
      `test/statifier_persistence_test.exs` already models.
- [ ] The blob layer decodes nothing (ADR-0003 decision 1). Decided by one
      command, with no human classification of the hits:
      `grep -nE '\bStatifier\.(Position|Machine|MachineState)[A-Za-z.]*\.[a-z_]+\(' lib/statifier_persistence/storage/adapter.ex lib/statifier_persistence/storage/in_memory.ex`
      returns nothing. It matches a dotted **call** and not a prose or
      `@typedoc` mention of a module name, which is what the two files
      legitimately contain.
- [ ] `mix.exs` `deps/0` is unchanged - no dependency is added by this phase.

#### Manual Verification:
- [ ] The `@callback` docs are sufficient for someone to write an Ecto
      adapter without reading `in_memory.ex`.
- [ ] No callback signature mentions a surrogate key, a table name, or a
      prefix (ADR-0002's layering claim still literally true).
- [ ] `init/1`'s return shape is workable for an adapter whose handle is a
      repo module rather than a pid.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: The guarded facade

### Overview

The bead's centre of gravity: the one code path that turns a stored blob back
into a `Statifier.MachineState.t()`, with the identity guard applied
unconditionally and every refusal returned as a typed error. This phase needs
real compiled charts, so it also lands the SCXML fixture helper the
conformance suite reuses in Phase 4.

### Changes Required:

#### 1. Test-side chart fixtures

**File**: `lib/statifier_persistence/testing/charts.ex`
**Changes**: New. Two tiny SCXML documents that differ by one state, so their
content hashes differ, compiled through `Statifier.compile/2` and returned as
`{source, machine}`, plus a helper returning an unidentified machine (a
struct update stripping `:identity` from a compiled one).

It goes straight into `lib/` under the `StatifierPersistence.Testing.*`
namespace rather than into `test/support/`, even though only this phase's
tests use it yet: Phase 4's conformance template lives in `lib/` and may not
reference anything under `test/` (ADR-0003 decision 5, st-ADR-0053's rule),
so putting it in `test/support/` now would only mean moving it in Phase 4
and rewriting Phase 3's tests to follow. Its lines are covered by this
phase's own tests, so the coverage floor is unaffected.

Two charts that differ is the whole point: the mismatch test must be a real
recompiled revision, not a hand-forged identity struct, or it does not
exercise what the guard exists to catch.

#### 2. The facade

**File**: `lib/statifier_persistence/storage.ex`
**Changes**: New module. A handle struct plus the guarded API.

```elixir
defmodule StatifierPersistence.Storage do
  @moduledoc """
  The guarded entry point ... every load is checked against the chart
  revision that produced it (ADR-0003 decision 2).
  """

  alias Statifier.{Machine, MachineState, Position}
  alias Statifier.Machine.Identity
  alias StatifierPersistence.Storage.Adapter

  @enforce_keys [:adapter, :opts]
  defstruct [:adapter, :opts]

  @type t :: %__MODULE__{adapter: module(), opts: Adapter.opts()}

  @type error ::
          Adapter.error()
          | :not_a_statifier_blob
          | :unidentified_chart
          | {:unsupported_format_version, term()}
          | {:identity_mismatch, Identity.t(), Identity.t() | nil}

  @spec new(adapter :: module(), opts :: Adapter.opts()) :: {:ok, t()} | {:error, error()}

  @spec save_chart(store :: t(), machine :: Machine.t(), chart_blob :: binary()) ::
          :ok | {:error, error()}

  @spec fetch_chart(store :: t(), content_hash :: Adapter.content_hash()) ::
          {:ok, Adapter.chart_record()} | {:error, error()}

  @spec save_position(store :: t(), session_id :: Adapter.session_id(), machine_state :: MachineState.t()) ::
          :ok | {:error, error()}

  @spec load_position(store :: t(), session_id :: Adapter.session_id(), machine :: Machine.t()) ::
          {:ok, MachineState.t()} | {:error, error()}
end
```

The store handle is the first argument everywhere, per the project's
pipeline-threading convention.

`save_chart/3` derives the `chart_record`'s `content_hash` and
`identity_blob` from `Machine.identity(machine)` - never from a caller-passed
value - and returns `{:error, :unidentified_chart}` when it is `nil`, exactly
as `save_position/3` does below. The `chart_blob` argument is stored verbatim
and is the one thing this function does not derive or inspect (Implementation
Approach idea 3). The symmetry is deliberate: both writers refuse an
unidentified machine, so neither can put a row in the store that a later load
has no way to check.

`save_position/3` encodes with `Position.to_binary/1` and derives
`content_hash` and `identity_blob` from `Machine.identity/1` on the state's
own machine, so a caller cannot store a position under a hash that disagrees
with its blob. `{:error, :unidentified_chart}` from `to_binary/1` is
returned, never rescued - which is st-ADR-0052 decision 4's structural
guarantee arriving intact at this layer: no unverifiable blob can be written
through this API either.

`load_position/3` runs in this order, and the order is the contract:

1. `fetch_position/2` on the adapter -> `:position_not_found` or
   `{:adapter, term}` pass straight through.
2. **The cheap pre-check.** Decode the stored `identity_blob` with
   `Identity.from_binary/1` and compare it against `Machine.identity(machine)`
   with `Identity.matches?/2` - never `==/2` (st-ADR-0052 decision 1). A
   mismatch returns `{:error, {:identity_mismatch, stored, supplied}}`, the
   same arm and the same argument order `Position.from_binary/2` would have
   produced, without paying the position decode. `Machine.identity/1` being
   `nil` returns `{:error, :unidentified_chart}`, matching upstream. A stored
   `identity_blob` that does not decode returns
   `{:error, :not_a_statifier_blob}`.
3. `Position.from_binary(position_blob, machine)` - the authoritative check.
   Its result is returned unchanged, all four error arms included.

Step 2 is an optimization that must never disagree with step 3, which is why
it reuses `matches?/2` and the same arms rather than comparing hash strings.
The conformance suite asserts they agree by exercising a mismatch and getting
one arm, whichever check fired.

`load_position/3`'s `@doc` must state that the returned `MachineState` has
`routes` and `invoke_types` set to `nil` by upstream design, and that
re-stamping them is the caller's job (sp-4an.2) - otherwise the first host to
drive the result gets a confusing failure well downstream of here.

#### 3. Facade tests

**File**: `test/statifier_persistence/storage_test.exs`
**Changes**: New. Against `InMemory`:

- Round trip: save a position for a compiled chart, load it back with the
  same machine, and match the restored configuration, datamodel, and
  counters against the saved `MachineState`.
- **The mismatch**: save against chart A, load with chart B's machine,
  assert `{:error, {:identity_mismatch, %Identity{}, %Identity{}}}` and that
  both identities carry the two distinct content hashes. Assert the call
  returns rather than raises.
- Corrupt bytes stored as a position blob -> `{:error, :not_a_statifier_blob}`.
- An unidentified `Machine` on the load side ->
  `{:error, :unidentified_chart}`. Note that
  `Statifier.Compiler.compile/1` takes a `Statifier.Document.t()`, not
  source bytes (`deps/statifier/lib/statifier/compiler.ex:208`), so the
  cheap way to build one in a test is a struct update stripping `:identity`
  from an already-compiled machine. Put that constructor in the fixtures
  module so both this suite and the conformance template use the same one.
- `save_position/3` with an unidentified machine -> the same arm, and nothing
  written.
- `:position_not_found` for an unknown session id.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`), coverage at or above 90.
- [ ] The mismatch test asserts a returned `{:error, {:identity_mismatch, _, _}}`
      tuple, and the suite contains no `assert_raise` for the guard path.
- [ ] Every new test that asserts `lib/` behavior is sabotage-verified with a
      one-line `# sabotage: ...` note above it. The guard test's mutation
      must be the load path skipping the check - deleting the
      `Position.from_binary/2` call's guard and returning the decoded state
      anyway must go red.
- [ ] `grep -n "rescue\|raise" lib/statifier_persistence/storage.ex` returns
      nothing (errors are events; no rescue-to-default at a leaf).
- [ ] Dialyzer is clean, which is what checks the `@spec` error unions match
      what the code can actually return.

#### Manual Verification:
- [ ] The pre-check and the authoritative check genuinely cannot disagree -
      read both against `deps/statifier/lib/statifier/position.ex:151-160`.
- [ ] The `{:identity_mismatch, expected, actual}` argument order matches
      upstream's (blob first, supplied machine second), so a host's log line
      means the same thing at both layers.
- [ ] The `load_position/3` doc's statement about `routes` / `invoke_types`
      is accurate against the pinned engine and points at sp-4an.2.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: The reusable conformance suite

### Overview

Lift the adapter-facing assertions out of the two ad-hoc test files into one
`ExUnit.CaseTemplate` in `lib/`, so sp-4an.3's Ecto adapter runs the identical
suite by `use`-ing it. This is the phase that makes "a conformance test suite
the future Ecto adapter can reuse" a fact rather than an aspiration.

### Changes Required:

#### 1. The case template

**File**: `lib/statifier_persistence/testing/storage_conformance.ex`
**Changes**: New module, `use ExUnit.CaseTemplate`, parameterized by the
adapter under test.

```elixir
defmodule StatifierPersistence.Testing.StorageConformance do
  @moduledoc """
  The conformance suite every `StatifierPersistence.Storage.Adapter` must
  pass. Ships in `lib/` (ADR-0003 decision 5, st-ADR-0053's shape) so an
  adapter in another package runs the identical suite:

      defmodule MyApp.EctoAdapterConformanceTest do
        use StatifierPersistence.Testing.StorageConformance,
          adapter: MyApp.EctoAdapter,
          opts: [repo: MyApp.Repo]
      end
  """
end
```

The suite covers, at minimum:

- Adapter level: chart round trip; idempotent `save_chart/2` on a repeated
  content hash; position round trip; `save_position/2` overwrite;
  `:chart_not_found`; `:position_not_found`; blobs returned byte-identical to
  what was stored (an adapter must not normalize, truncate, or re-encode
  bytes - a real hazard for a column type chosen carelessly).
- Facade level, driven through `StatifierPersistence.Storage` over the
  adapter: the guarded round trip; the cross-revision mismatch returning
  `{:identity_mismatch, _, _}`; corrupt bytes returning
  `:not_a_statifier_blob`; an unidentified machine returning
  `:unidentified_chart`. These belong in the conformance suite and not only
  in Phase 3's tests, because the guard must be shown to hold *over every
  adapter*, which is the whole claim ADR-0003 decision 2 makes.

Setup is the adapter's own `init/1` plus a per-test isolation hook the
template calls if the adapter exports one, so an Ecto adapter can wrap each
test in a sandboxed transaction. Declare it as an optional callback
(`@optional_callbacks`) on the behaviour in this phase rather than inventing
an untyped convention; a default no-op keeps `InMemory` unaffected.

**This widens the behaviour's contract surface, so it is an ADR change, not
just a code change.** ADR-0001's Decision sets the bar for a record at "the
decision changes what a host reads - the behaviour's contract surface", and
its Consequences require decisions to land as ADRs before or with the code
that encodes them. Adding an optional `@callback` to
`StatifierPersistence.Storage.Adapter` clears that bar even though it is
optional: a future adapter author reading ADR-0003 must find the isolation
hook there, not only in the template's source. See changes item 5 below.

The chart fixtures the suite needs are already at
`lib/statifier_persistence/testing/charts.ex` from Phase 3, for exactly this
reason, so nothing moves here. Both modules are
`StatifierPersistence.Testing.*`, so the one-way namespace rule holds.

#### 2. Run it against the reference adapter

**File**: `test/statifier_persistence/storage/in_memory_conformance_test.exs`
**Changes**: New, three lines:

```elixir
defmodule StatifierPersistence.Storage.InMemoryConformanceTest do
  use StatifierPersistence.Testing.StorageConformance,
    adapter: StatifierPersistence.Storage.InMemory,
    opts: []
end
```

#### 3. Retire the superseded tests

**Files**: `test/statifier_persistence/storage/in_memory_test.exs`,
`test/statifier_persistence/storage_test.exs`
**Changes**: Delete the assertions the conformance suite now makes; keep only
what is genuinely specific to `InMemory` (its Agent lifecycle) or to the
facade's own construction (`new/2`). Two copies of the same assertion is how a
conformance suite decays into a suite nobody trusts.

#### 4. Amend ADR-0003 for the isolation callback

**File**: `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`
**Changes**: Extend decision 5 (or append a dated amendment note under the
Status line, matching how statifier-ex's own records mark amendments) to
record the optional per-test isolation callback as part of the contract
surface: what it is for, that it is optional with a no-op default, and that
an adapter needing no isolation does not implement it. Update the
`docs/adr/README.md` row's summary only if the amendment changes what the
one-line summary claims.

Doing it in this phase rather than pre-emptively in Phase 1 is deliberate:
the hook's shape is not knowable until the template that calls it exists, and
ADR-0001 asks for the record to land *with* the code that encodes it, not
ahead of a design that has not been written yet.

#### 5. Coverage bookkeeping

**File**: `coveralls.json`
**Changes**: If, and only if, the full gate reports the coverage floor
threatened by macro-generated lines in
`lib/statifier_persistence/testing/`, add that directory to `skip_files`
alongside `test/support/`. The rationale, recorded in the commit message: it
is test-side surface that ships in `lib/` for distribution reasons only
(ADR-0003 decision 5), and its coverage is asserted by the fact that its
suite runs, not by a line count. Do not pre-emptively add it - measure first.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`), coverage at or above 90.
- [ ] `test/statifier_persistence/storage/in_memory_conformance_test.exs`
      contains no `test` block of its own - the whole suite comes from the
      template.
- [ ] `grep -rn "StatifierPersistence.Testing" lib/ --include=*.ex | grep -v
      "lib/statifier_persistence/testing/"` returns nothing: no module in
      `lib/` outside the `Testing` namespace references anything inside it
      (ADR-0003 decision 5, st-ADR-0053's rule).
- [ ] `grep -rn "test/support" lib/` returns nothing.
- [ ] Every `@callback` and `@optional_callbacks` entry on
      `StatifierPersistence.Storage.Adapter` is named in
      `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md` -
      in particular the isolation hook added by this phase. The ADR file
      remains free of typographic dashes and curly quotes
      (`grep -nP '[\x{2010}-\x{2015}\x{2018}\x{2019}\x{201C}\x{201D}]'`
      returns nothing).
- [ ] Every new or moved test that asserts `lib/` behavior is
      sabotage-verified with its one-line `# sabotage: ...` note; for a
      template-generated test the note lives above the generating `test`
      block in the template.
- [ ] The byte-identity assertion goes red when the adapter is mutated to
      return a re-encoded blob.

#### Manual Verification:
- [ ] The template can be `use`d from a package that depends on this one -
      no reference to anything under this repo's `test/`, and the doc example
      is copy-pasteable.
- [ ] The optional per-test isolation hook is adequate for an Ecto sandbox;
      read it against how `Ecto.Adapters.SQL.Sandbox` wants to be checked out.
- [ ] Deleting the superseded assertions lost no coverage of a real
      behaviour, only duplication.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_persistence/storage/in_memory_test.exs` - the reference
  adapter's own mechanics: Agent lifecycle, `init/1` idempotence, and any
  behaviour that is `InMemory`'s alone rather than every adapter's.
- `test/statifier_persistence/storage_test.exs` - the facade's construction
  and the arms that do not need an adapter to vary.
- `test/statifier_persistence/storage/in_memory_conformance_test.exs` - the
  shared suite, run against the reference adapter.

Key edge cases, all of them arms that must return rather than raise:

- A position saved against chart A loaded with chart B's machine. The two
  charts must be genuinely different documents so the hashes differ for the
  right reason.
- An unidentified `Machine` on either side of a load, and on the save side.
- A stored position blob that is not this library's envelope at all: random
  bytes, and a foreign `:erlang.term_to_binary/1` blob. Both are
  `:not_a_statifier_blob`, and the foreign-blob case is the one that proves
  the check is the envelope tag and not a byte-length heuristic.
- A stored `identity_blob` that does not decode, with a perfectly good
  position blob beside it - the pre-check must not mask the authoritative
  check by returning something the position decode would not have.
- Blob byte-identity across a store/fetch round trip.
- Both not-found arms.

An `{:unsupported_format_version, v}` blob cannot be produced honestly
against the pinned engine (`Position.format_version/0` is `2` and version 1
is read rather than refused). The suite therefore asserts that arm is
declared in the facade's `@type error` and reachable in the `@spec` - which
dialyzer checks - rather than faking a blob to force it. Hand-forging an
envelope with a fictional version number would test this package against a
shape upstream does not produce, which is worse than not testing it.

### Manual Testing Steps:

1. In `iex -S mix`, compile two chart revisions that differ by one state,
   save a position against the first, and load it with the second. Confirm
   the return is `{:error, {:identity_mismatch, expected, actual}}`, that
   both identities are present with different content hashes, and that
   nothing was raised or logged as a crash.
2. Load the same position with the correct machine and confirm the restored
   configuration equals the saved one.
3. Confirm the restored `MachineState` has `routes` and `invoke_types` set to
   `nil`, matching what `load_position/3`'s doc promises and what sp-4an.2
   will have to re-stamp.
4. Write a throwaway second adapter module in `iex` (a Map in the process
   dictionary is enough), point the conformance template at it, and confirm
   the suite fails informatively for a missing callback and for one that
   silently drops the identity columns.
5. Run the umbrella's terminology scan from `docs/terminology-firewall.md`
   over the whole diff before any push.

## Open Questions

Every question below was recorded rather than resolved because this plan was
produced unattended. Each has a **working answer already encoded in the
plan**, so no phase is blocked - the question is whether the working answer
is the one the maintainer wants. None of them changes the phase structure.

1. **Chart blob provenance.** The bead's note (verified against `1ad889a`)
   says persist the SCXML source text. The pinned dep (`0c557068`) has
   `Statifier.Chart.to_binary/1`, which bundles source, compile opts, and
   identity into one envelope, and `deps/statifier/docs/persistence.md` now
   presents that as the two-line reload recipe. *Working answer*: the
   behaviour stores an opaque `chart_blob` and says nothing about what
   produced it, so both work and this package takes no dependency on a module
   that postdates some pins. If the maintainer would rather this package
   commit to `Statifier.Chart`, that is a one-line change to ADR-0003's
   Context and a tightened `save_chart/3` signature.
2. **Position key: engine session id, or a run id.** ADR-0002 decision 5
   establishes *runs* as this package's vocabulary and gives
   `statifier_runs` a nullable `session_id`. This bead predates the run
   lifecycle (sp-4an.2). *Working answer*: key positions by the engine
   session id, because it is an engine identity (ADR-0002 decision 1's
   category) and this layer is forbidden surrogate keys. If sp-4an.2 decides
   a run id is the durable key and a session id is optional, this signature
   changes before any adapter ships - which is the cheap moment for it.
3. **`init/1` on the behaviour.** Included so an adapter has a declared setup
   hook and the facade has one call to make when building a handle. It could
   equally be left to each adapter's own API. *Working answer*: keep it;
   an Ecto adapter checking its repo is reachable wants somewhere to fail.
4. **The cheap identity pre-check in `load_position/3`.** It makes the stored
   `identity_blob` load-bearing and avoids a full position decode on a
   mismatch, at the cost of two code paths that must agree. *Working
   answer*: keep it, reusing `Identity.matches?/2` and the identical error
   arms so they cannot diverge in meaning. Dropping it would simplify the
   facade at the cost of decoding every stale position in full.
5. **Coverage treatment of `lib/statifier_persistence/testing/`.** Phase 4
   measures before deciding whether to add it to `coveralls.json`'s
   `skip_files`. *Working answer*: measure first, skip only if the floor is
   actually threatened, and record the reason in the commit message.
6. **Whether ADR-0003 should also state what reopens ADR-0002's layering
   claim.** ADR-0002's own Consequences already names it. *Working answer*:
   adopt by reference from ADR-0003's Context rather than restate, per
   ADR-0001's "adopted by reference, never restated in a way that could
   drift".

## References

- Bead: `sp-5qa` (its 2026-08-21 note is the research input for this plan)
- Parent: the `sp-4an` charter tree; sibling `sp-4an.2` (run lifecycle and
  stepper), `sp-4an.3` (Ecto adapter, the conformance suite's second consumer)
- This repo's ADRs: `docs/adr/0001-record-architecture-decisions.md`,
  `docs/adr/0002-configurable-keys-and-table-names.md`
- Upstream contract (vendored at `deps/statifier/`, pinned to `0c557068` in
  `mix.lock:18`):
  - `deps/statifier/docs/persistence.md`
  - `deps/statifier/docs/adr/0052-chart-identity-and-position-serialization.md`
  - `deps/statifier/docs/adr/0060-resuming-a-session-from-a-persisted-position.md`
  - `deps/statifier/lib/statifier/position.ex:88-160`
  - `deps/statifier/lib/statifier/machine/identity.ex:39-110`
  - `deps/statifier/lib/statifier/chart.ex:53-136`
  - `deps/statifier/lib/statifier.ex:101`
  - `deps/statifier/lib/statifier/machine.ex:387`
- Pattern to model the conformance template after:
  `deps/statifier/lib/statifier/testing/case.ex:1-12` (st-ADR-0053)
- Gate configuration: `.quality.exs`, `coveralls.json`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The record reads as a decision, not a design sketch: someone citing
      "ADR-0003 decision 2" ends the argument about where the guard lives.
- [ ] Nothing in it contradicts ADR-0001 or ADR-0002, and the ADR-0002
      layering claim is adopted by reference rather than restated in a way
      that could drift.
- [ ] The cross-repo citations use the `st-ADR-NNNN` form and the bare
      `ADR-NNNN` form is only ever this repo's own.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
