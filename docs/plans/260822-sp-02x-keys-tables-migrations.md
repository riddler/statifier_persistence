# Configurable keys, table names, and migrations (ADR-0002) Implementation Plan

## Overview

Implement ADR-0002's deliverables that must exist ahead of the Ecto
adapter's first migration: the key-generator behaviour (UXID default,
UUIDv7, bigserial, custom), the `use StatifierPersistence.Ecto` macro that
carries a host's compile-time configuration, and the versioned
Oban.Migration-style migrations helper that takes the same options - plus
the two epic-entry decisions the sp-4an.3 epic left open (dependency shape
and test harness), recorded as ADR-0005. Bead: sp-02x (first task of the
sp-4an.3 epic).

## Current State Analysis

- `mix.exs:52-59` records the open dependency question verbatim: "The Ecto
  adapter epic decides its own dependency shape (ecto_sql optional vs a
  separate statifier_ecto package) when that work starts." No Ecto anywhere
  in the tree yet; no `config/` directory; no database in CI
  (`.github/workflows/ci.yml` runs the bare gate on ubuntu-latest).
- ADR-0002 (accepted) fixes: engine identities stored verbatim and
  non-configurable; surrogate PKs compile-time configurable (`:uxid`
  default via the `uxid` package, `:uuid` as UUIDv7, `:bigserial`,
  `{module, opts}` against a key-generator behaviour); configuration on the
  host's module via `use StatifierPersistence.Ecto` (no app env); a
  versioned migrations helper taking the same options; `statifier_` table
  prefix with a per-table override map and a separate Postgres-schema
  option; runs vocabulary with a nullable `session_id` column.
- ADR-0003/ADR-0004 fix the adapter surface this DDL must eventually serve:
  charts keyed by `content_hash` (verbatim, unique), positions keyed by
  engine `session_id`, runs keyed by caller-supplied `run_id` with
  `{status, content_hash, identity_blob, position_blob | nil, failure |
  nil}`, and an optional `lock_run/3` an Ecto adapter implements as a
  transaction-scoped row lock (`SELECT ... FOR UPDATE`) - which constrains
  the test-harness choice (see Implementation Approach).
- The conformance suite
  (`lib/statifier_persistence/testing/storage_conformance.ex`) and the
  optional `isolate/1` callback (`lib/statifier_persistence/storage/adapter.ex:211-224`)
  already anticipate an `Ecto.Adapters.SQL.Sandbox` checkout per test.

### Key Discoveries:

- `lib/statifier_persistence/storage/adapter.ex:29-63` - the storage
  contract's field set is the column list; nothing else may leak into the
  behaviour (ADR-0002 decision 1, ADR-0003 decision 3).
- ADR-0002 decision 4 sketches three tables (`statifier_charts`,
  `statifier_chart_versions`, `statifier_runs`), but the behaviour keys
  charts by content hash only - there is no callback a logical-chart table
  would serve. V01 therefore creates `charts` (hash-keyed),
  `positions`, and `runs`, recording the collapse as a dated amendment to
  ADR-0002 (same unexercised-contract reasoning ADR-0003/0004 use).
- `docs/plans/260822-sp-4an.2.1-run-lifecycle-executor-seam-stepper.md` -
  the phase/gate discipline this plan mirrors.
- `.github/workflows/ci.yml` needs a Postgres service container; the gate
  (`mix quality`) runs the full test suite, so database-backed tests must
  find a server in CI and locally.

## Desired End State

A host writes:

    defmodule MyApp.Persistence do
      use StatifierPersistence.Ecto, repo: MyApp.Repo
    end

and gets: resolved configuration readable via
`MyApp.Persistence.__statifier_persistence__/1`, three schema modules
(`MyApp.Persistence.Chart`, `.Position`, `.Run`) with UXID string primary
keys (`chart_`/`pos_`/`run_` prefixes) and the engine identity columns
verbatim, and one supported way to create the tables:

    defmodule MyApp.Repo.Migrations.AddStatifierPersistence do
      use Ecto.Migration
      def up, do: StatifierPersistence.Ecto.Migrations.up(for: MyApp.Persistence)
      def down, do: StatifierPersistence.Ecto.Migrations.down(for: MyApp.Persistence)
    end

Every knob (`key:`, `table_prefix:`, `tables:`, `prefix:`) changes both the
schemas and the DDL through one shared config resolver, so they cannot
disagree. Verified end-to-end against real Postgres: migrate up under each
key option, insert through the generated schemas, assert the engine
identity columns and their unique indexes are identical across all key
configurations, migrate down clean.

## What We're NOT Doing

- **The Ecto adapter itself** (implementing
  `StatifierPersistence.Storage.Adapter` over these schemas, `lock_run/3`
  as a row lock, passing the conformance suite) - that is the epic's next
  task, planned separately on top of this one.
- **A logical-chart / chart-versions split.** ADR-0002's sketch named
  `statifier_chart_versions`; the behaviour exercises only a hash-keyed
  chart store, so V01 ships `charts`/`positions`/`runs` and the ADR-0002
  amendment records why. A logical-chart table returns when a real embedder
  needs one (the charter's own design rule).
- **Tenancy columns.** ADR-0002 says they ride the same `use`; no host has
  specified any yet, and inventing placeholder columns is the unexercised
  contract ADR-0003's Consequences warn about. The option surface leaves
  room (documented), nothing more.
- **Writing `session_id` on runs from library code.** The column exists
  (ADR-0002 decision 5, accepted) as nullable DDL; the run lifecycle does
  not populate it yet - that is host/adapter territory later.
- **SQLite or in-memory-fake harnesses.** Rejected in ADR-0005: `lock_run/3`
  needs real `SELECT ... FOR UPDATE` semantics and the conformance bar is
  meaningless against a fake.
- **Editing `.quality.exs`** (excluded by campaign consent) - the gate is
  taken as it stands.

## Implementation Approach

Four phases, each independently gate-green and committable. Phase 1 makes
the two epic-entry decisions (ADR-0005) and stands up the Postgres harness
so later phases can test against a real database; Phase 2 is the pure
key-generator layer; Phase 3 the `use` macro over a shared `Config`
resolver; Phase 4 the versioned migrations helper reading the same
`Config`, proven live against Postgres under every key option.

Dependency shape (ADR-0005, decision made here per the epic's charge): the
Ecto layer lives **in this package** behind `{:ecto_sql, "~> 3.10",
optional: true}` - a separate `statifier_ecto` package would duplicate the
conformance/test surface and split one contract across two repos for no
consumer benefit; `use StatifierPersistence.Ecto` (ADR-0002 decision 3,
accepted) already names this package as the home. Modules that reference
Ecto are wrapped in `if Code.ensure_loaded?(Ecto)` so a host without
ecto_sql still compiles this package. `uxid` becomes a required dependency
(ADR-0002 decision 2: the default must work out of the box); `postgrex` is
`only: :test` here - a host brings its own driver.

Test harness (ADR-0005): real Postgres - `docker compose up -d db` locally
(port/credentials overridable via `PG*` env vars), a `postgres` service
container in CI. Database-backed tests are ordinary tests in the ordinary
suite; there is no tag that skips them when the server is absent, because
an auto-skipped database suite is the gate weakening `CLAUDE.md` forbids.

## Phase 1: ADR-0005, dependencies, and the Postgres test harness

### Overview

Record the two epic-entry decisions; add the dependencies; stand up a real
Postgres the suite and CI both reach; amend ADR-0002's table sketch.

### Changes Required:

#### 1. ADR-0005
**File**: `docs/adr/0005-ecto-in-package-and-postgres-test-harness.md`
**Changes**: New record, two decisions with the reasoning above: (1) the
Ecto layer ships in this package behind optional ecto_sql, uxid required,
postgrex test-only, `Code.ensure_loaded?` guards; (2) the test harness is
real Postgres with the SQL sandbox, compose locally / service container in
CI, no skip tag. Consequences must state the standing operational cost
explicitly: from this record on, every `mix quality` run in this
repository requires a reachable Postgres server, by design - and what
would reopen each decision (a host that cannot take uxid transitively; a
second database the adapter must support). Update `docs/adr/README.md`
index.

The whole harness lands here rather than incrementally with Phase 4,
deliberately: ADR-0005 is the epic-entry decision Phases 2-4 are written
against, the CI/compose wiring is the riskiest-to-debug piece so it fails
early on its own commit, and only a connectivity smoke test consumes it
until Phase 4 - an accepted, noted idle stretch.

#### 2. ADR-0002 amendment
**File**: `docs/adr/0002-configurable-keys-and-table-names.md`
**Changes**: Dated amendment under decision 4 (house style: the
parenthesized amendment blocks ADR-0003 uses): V01's table set is
`charts`/`positions`/`runs` - the behaviour (ADR-0003 decision 3) keys
charts by content hash only and stores positions by session id, so the
`chart_versions` sketch collapses into the hash-keyed `charts` table and
`positions` joins the set under the same prefix knob; UXID row prefixes
become `chart_`/`pos_`/`run_` accordingly. A second, shorter parenthetical
under decision 3 records that tenancy columns remain unimplemented option
surface - deferred, not changed - so a reader of ADR-0002 alone learns the
promise is not yet delivered.

#### 3. Dependencies
**File**: `mix.exs`
**Changes**: Add `{:uxid, "~> 2.0"}` (2.9.0 is current on Hex),
`{:ecto_sql, "~> 3.10", optional: true}`, `{:postgrex, "~> 0.19", only:
:test}`; replace the recorded open
question in the deps comment with a pointer to ADR-0005.

#### 4. Harness
**Files**: `docker-compose.yml`, `config/config.exs`, `config/test.exs`,
`test/support/test_repo.ex`, `test/test_helper.exs`, `README.md`
**Changes**: Compose file with one `postgres:17` service (healthcheck,
host port from `PGPORT`, default 5432). `config/test.exs` configures
`StatifierPersistence.TestRepo` from `PG*` env vars with those defaults,
`pool: Ecto.Adapters.SQL.Sandbox`. `test_helper.exs` creates the database
if absent (`storage_up`), starts the repo, runs the package migrations
(Phase 4 extends this; in Phase 1 it only starts the repo), sets sandbox
`:manual`. README gains a short "Running the tests" note (compose command,
env vars). A smoke test asserts the repo answers `SELECT 1` so a missing
server fails loudly with a clear message, not obscurely; because the pool
is the SQL sandbox in `:manual` mode, the smoke test performs an explicit
`Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)` in its setup.

#### 5. CI
**File**: `.github/workflows/ci.yml`
**Changes**: Add a `postgres:17` service to the `gate` job (env
`POSTGRES_PASSWORD: postgres`, port 5432 mapped, `pg_isready`
healthcheck); export the matching `PG*` env at the job level.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes locally (`mix quality`), including the new
      smoke test against the compose Postgres
- [x] `mix gate.verify` passes
- [x] `mix deps.get` resolves uxid/ecto_sql/postgrex without conflicts

#### Manual Verification:
- [ ] CI run on the pushed branch is green with the service container
- [ ] ADR-0005 reads as a decision record, not a plan restatement

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In looped (`--loop`)
execution, Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end.

---

## Phase 2: The key-generator behaviour and its three implementations

### Overview

The pure layer: a behaviour fixing what a key scheme must answer, the
`:uxid`/`:uuid`/`:bigserial` implementations, and the resolver from
ADR-0002's option spellings to `{module, opts}`. No database.

### Changes Required:

#### 1. Behaviour and resolver
**File**: `lib/statifier_persistence/ecto/key_generator.ex`
**Changes**: `StatifierPersistence.Ecto.KeyGenerator` behaviour with three
callbacks the schemas and DDL both consume:

```elixir
@callback ecto_type(opts :: keyword()) :: atom()
# schema field type: :string | Ecto.UUID | :id

@callback migration_type(opts :: keyword()) :: atom()
# column type for DDL: :text | :uuid | :bigserial

@callback autogenerate(table :: :charts | :positions | :runs, opts :: keyword()) ::
            {module(), atom(), [term()]} | nil
# Ecto @primary_key autogenerate MFA; nil = database-assigned
```

plus `resolve(:uxid | :uuid | :bigserial | {module, opts}) ::
{module, keyword()}` mapping ADR-0002's spellings onto implementations
(`{Mod, opts}` passes through after a behaviour check). Wrapped in the
`Code.ensure_loaded?(Ecto)` guard only where Ecto types are referenced
(the behaviour itself is Ecto-free except `Ecto.UUID` in one
implementation).

#### 2. Implementations
**Files**: `lib/statifier_persistence/ecto/key_generator/uxid.ex`,
`.../uuid_v7.ex`, `.../bigserial.ex`
**Changes**: UXID: `:string`/`:text`, autogenerate via the `uxid` package
with per-table prefixes `chart_`/`pos_`/`run_` (ADR-0002 amendment).
UUIDv7: `Ecto.UUID`/`:uuid`, RFC 9562 v7 generation implemented here
(48-bit ms timestamp, version 7, variant 2, random tail - ~15 lines;
Ecto.UUID is v4, and a dependency for one function is not worth taking),
encoded through `Ecto.UUID.load/1`. Bigserial: `:id`/`:bigserial`,
`autogenerate/2` returns nil.

#### 3. Tests
**File**: `test/statifier_persistence/ecto/key_generator_test.exs`
**Changes**: Resolver mapping for all four spellings (including the
behaviour check refusing a non-implementing module); UXID keys carry the
right per-table prefix and are k-sortable in generation order; UUIDv7 keys
are valid UUID strings with version nibble 7 and variant bits 10, and sort
by generation time across a millisecond boundary; bigserial declares
database assignment. Sabotage each per repo convention.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`)
- [x] `mix gate.verify` passes

#### Manual Verification:
- [ ] Generated UXID/UUIDv7 examples eyeballed once for sanity

**Implementation Note**: same loop/full-gate discipline as Phase 1.

---

## Phase 3: `use StatifierPersistence.Ecto` - config and schemas on the host's module

### Overview

One shared config resolver, and the `use` macro that validates options at
compile time, exposes the resolved config, and defines the three schema
modules - the "same options" half of ADR-0002 decision 3's
schemas-and-DDL-cannot-disagree rule.

### Changes Required:

#### 1. Config resolver
**File**: `lib/statifier_persistence/ecto/config.ex`
**Changes**: `StatifierPersistence.Ecto.Config` struct + `new/1`:
validates `repo:` (required), `key:` (default `:uxid`, resolved via
`KeyGenerator.resolve/1`), `table_prefix:` (default `"statifier_"`),
`tables:` (per-table override map, keys `:charts | :positions | :runs`),
`prefix:` (Postgres schema, default nil). Rejects unknown options and
unknown table keys with a clear `ArgumentError` at compile time. Exposes
`table(config, :runs)` etc. This one module is what Phase 4's migrations
helper also consumes - the single definition site.

#### 2. The macro
**File**: `lib/statifier_persistence/ecto.ex`
**Changes**: `__using__/1` builds the `Config` at compile time, defines
`__statifier_persistence__(:config | :repo)` on the host module, and
defines `Host.Chart`, `Host.Position`, `Host.Run` schema modules:
configured PK (type + autogenerate MFA from the key generator;
`autogenerate: false, read_after_writes: true` for database-assigned),
`@schema_prefix` from `prefix:`, source from `Config.table/2`, engine
identity columns verbatim (`content_hash`, `session_id`, `run_id` as
`:string`; `identity_blob`/`chart_blob`/`position_blob` as `:binary`;
`status`/`failure` as `:string`; `timestamps(type: :utc_datetime_usec)`).
Whole file inside the `Code.ensure_loaded?(Ecto)` guard.

#### 3. Tests
**File**: `test/statifier_persistence/ecto_test.exs` (+ fixture host
modules under `test/support/`)
**Changes**: Zero-options-beyond-repo host gets UXID string PKs and
`statifier_*` sources (the acceptance criterion's "defaults work with zero
options beyond repo:"); a fully-overridden host (uuid key, custom prefix,
per-table override, Postgres schema) reflects every knob in
`__schema__(:source)`, `__schema__(:type, :id)`, `@schema_prefix`, and PK
autogeneration; a bigserial host declares db-assigned keys; invalid
options raise at compile time (asserted via `Code.compile_string/1` in the
test); the moduledoc's zero-config host example compiles as written
(asserted by compiling the snippet verbatim in a test, so it cannot drift
from the macro's real behavior). Sabotage per convention.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`)
- [x] `mix gate.verify` passes
- [x] The moduledoc's zero-config example compiles verbatim in a test

#### Manual Verification:
- [ ] Schema module names and option spellings read as a host author would
      expect (naming judgment, not machine-checkable)

**Implementation Note**: same loop/full-gate discipline. Schemas are
exercised against live DDL in Phase 4; in this phase their metadata is the
test surface.

---

## Phase 4: The versioned migrations helper, proven live

### Overview

`StatifierPersistence.Ecto.Migrations` in the Oban.Migration mold: V01
DDL generated from the same `Config`, migrated up and down against real
Postgres under every key option, with the identity columns proven
identical across all of them.

### Changes Required:

#### 1. The helper
**Files**: `lib/statifier_persistence/ecto/migrations.ex`,
`lib/statifier_persistence/ecto/migrations/v01.ex`
**Changes**: `Migrations.up(opts)` / `down(opts)`: `for: HostModule` reads
the host's compiled `Config` (the no-drift path); alternatively the same
literal options `use` takes, funneled through `Config.new/1` - one
resolver, both doors. `version:` selects the target (only V01 exists;
the versioned shape is the deliverable). V01 creates, per `Config`:
`<prefix>charts` (PK per key config; `content_hash` text NOT NULL UNIQUE;
`identity_blob`/`chart_blob` bytea NOT NULL; timestamps),
`<prefix>positions` (`session_id` text NOT NULL UNIQUE; `content_hash`
text NOT NULL; `identity_blob`/`position_blob` bytea NOT NULL;
timestamps), `<prefix>runs` (`run_id` text NOT NULL UNIQUE; `status` text
NOT NULL; `content_hash` text NOT NULL; `identity_blob` bytea NOT NULL;
`position_blob` bytea NULL; `failure` text NULL; `session_id` text NULL
per ADR-0002 decision 5; timestamps). All DDL honors `prefix:` (Postgres
schema) and the per-table overrides. `down` drops in reverse.

#### 2. Live tests
**File**: `test/statifier_persistence/ecto/migrations_test.exs`
**Changes**: `async: false`. For each key option (`:uxid`, `:uuid`,
`:bigserial`), a fixture host with a distinct `table_prefix`
(`kx_uxid_` etc. - which also exercises the prefix knob): run
`Ecto.Migrator` up with a generated migration module calling the helper
with `for:`; insert a row through each generated schema and read it back -
PK generated per config (or db-assigned), engine identity strings verbatim
byte-for-byte; assert via `information_schema` that the
`content_hash`/`session_id`/`run_id` columns and their unique indexes are
**identical across all three key configs** (the "identity guard provably
independent of the configured key" acceptance criterion at the DDL level -
the guard itself lives in the facade, `storage.ex`, and never touches a
surrogate key by construction, ADR-0003 decision 2); duplicate
`content_hash`/`run_id` inserts violate the unique index; migrate down
leaves no `kx_*` tables. One config additionally exercises the literal-
options door and the `prefix:` Postgres-schema option. Sabotage per
convention (e.g. drop the unique index from V01 -> duplicate-insert test
red).

#### 3. Test helper wiring
**File**: `test/test_helper.exs`
**Changes**: Migration tests manage their own DDL (up in `setup_all`,
down on exit) outside the sandbox: they switch the repo with
`Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)` for the duration of
`setup_all`/`on_exit` DDL and their own inserts (which is why the module
is `async: false`), restoring `:manual` afterward; the sandbox stays
`:manual` for everything else.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`)
- [ ] `mix gate.verify` passes

#### Manual Verification:
- [ ] `psql \d` on the migrated default tables matches ADR-0002's sketch
- [ ] CI green on the pushed branch (service container exercised by the
      live tests)

**Implementation Note**: same loop/full-gate discipline. This phase closes
sp-02x's acceptance criteria: behaviour + macro + helper exist and agree
on options (one `Config`), identity guard provably independent of the key,
defaults work with zero options beyond `repo:`.

---

## Testing Strategy

### Unit Tests:
- Key generators: pure format/ordering properties per implementation;
  resolver totality over ADR-0002's four spellings.
- Config/macro: compile-time validation and schema metadata under default,
  fully-overridden, and db-assigned configurations.
- Migrations: live round trips per key config; cross-config identity-column
  equality out of `information_schema`; unique-index enforcement;
  up/down symmetry.
- Every test asserting `lib/` behavior is sabotaged (break, verify red,
  revert, one-line note above the test) per repo convention.

### Manual Testing Steps:
1. `docker compose up -d db && mix quality` from a clean checkout.
2. Inspect `\d statifier_runs` in psql after the migration tests, compare
   against ADR-0002 decision 4/5.
3. Confirm the pushed branch's CI run is green.

## References

- Bead: `sp-02x` (parent epic `sp-4an.3`)
- ADRs: `docs/adr/0002-configurable-keys-and-table-names.md`,
  `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`,
  `docs/adr/0004-run-lifecycle-executor-seam-and-serialization.md`
- Adapter contract: `lib/statifier_persistence/storage/adapter.ex:29-63`
- Conformance suite (consumer of Phase 1's harness in the next task):
  `lib/statifier_persistence/testing/storage_conformance.ex`
- Precedent plan:
  `docs/plans/260822-sp-4an.2.1-run-lifecycle-executor-seam-stepper.md`
- Open question this resolves: `mix.exs:52-59` (dependency shape)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] CI run on the pushed branch is green with the service container
- [ ] ADR-0005 reads as a decision record, not a plan restatement

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In looped (`--loop`)
execution, Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end.

---

### Phase 2

- [ ] Generated UXID/UUIDv7 examples eyeballed once for sanity

**Implementation Note**: same loop/full-gate discipline as Phase 1.

---

### Phase 3

- [ ] Schema module names and option spellings read as a host author would
      expect (naming judgment, not machine-checkable)

**Implementation Note**: same loop/full-gate discipline. Schemas are
exercised against live DDL in Phase 4; in this phase their metadata is the
test surface.

---
