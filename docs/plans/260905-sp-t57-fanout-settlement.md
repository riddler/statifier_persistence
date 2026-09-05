# Tier A fan-out settlement Implementation Plan

**Status**: phases 1 and 2 landed on the branch (commits `4480ff4` and
`ac68f4e`); phases 3 to 6 remain. The Current State Analysis below
describes `origin/main`, which is what the phases were written against.

## Overview

Teach this package to settle a Tier A fan-out: an `<invoke>` whose one
invocation has N durable children, each carrying its item index, whose
completions are collected here and answered to the parent's door exactly
once, as a dense index-ordered list. statifier_oban owns the scheduling
half (its bead `sob-q3y`, this bead's `mirrors:` line); this package owns
settlement. Bead: sp-t57.

## Current State Analysis

The durable-subchart path exists and works for one child per invocation:

- `Run.Linkage` (`lib/statifier_persistence/run/linkage.ex`) carries four
  values under one reserved metadata key - `parent_run_id`, `invoke_id`,
  `child_index`, `content_hash` - and `child_index` is hard-coded `0` at
  its only writer (`driver.ex:914`, in the private `create_child/5`).
- `Driver.start_child/3` (`driver.ex:852`, private) refuses at open for an
  adapter that cannot enumerate children
  (`:child_listing_unsupported`), then resolves, identifies and creates the
  child.
- A child's completion is routed to the parent by `maybe_answer_parent/3`
  (`driver.ex:568`) -> `auto_answer_parent/3` (`:581`) ->
  `respond_to_parent/3` (`:545`) -> `done_invocation/5` (`:439`). The
  **first** child to finish therefore completes the whole invocation.
- A child's answer is not persisted anywhere: the run record
  (`storage/adapter.ex:78-86`) has no field for it, and V01's runs table
  (`ecto/migrations/v01.ex:66-80`) has no column for it. A completion is
  visible only to the drive that produced it.
- The only parent-side query is `Storage.list_runs_by_metadata/2`
  (`storage.ex:423`), which materialises whole records - `identity_blob`
  and `position_blob` included (`storage/ecto.ex:393-403`) - and V02 ships
  no index on `metadata` by design (`ecto/migrations/v02.ex:12-18`).
- `Runs.cascade_cancel/3` (`runs.ex:468`) walks live children of an
  invocation match and cancels them, and `perform/5`'s `:cancel_invoke`
  arm (`driver.ex:816-831`) is its caller.
- Migrations know versions 1 and 2 (`ecto/migrations.ex:52-58`) - phase 2
  is what adds V03.

So four things are missing: a linkage that says "one of N, under policy
P"; somewhere to keep a child's answer; a settlement test that does not
move N blobs; and a routing decision that sends a fan-out child's
completion to settlement rather than straight through the parent's door.

## Desired End State

A host (statifier_oban, through its host-wired `:child_starter` seam)
starts child `i` of `N` with

```elixir
StatifierPersistence.Driver.start_child_at(driver, parent_run_id, effect, i, n,
  policy: :all)
```

Each child runs as an ordinary run. When one reaches a terminal status its
outcome payload is written to its own run record, and a settlement section
runs under the **parent's** exclusion: an indexed status projection asks
whether all N indices are terminal, and only the settlement that finds
them all terminal reads the N payloads once, assembles the dense
index-ordered list, and answers the parent's existing door. Under
`policy: :first_error` a failing child first cancels its live siblings
through the existing cascade and asks the scheduler to cancel the start
jobs of the indices that never produced a run; both kinds read `cancelled`
at their index in the same dense list.

Verified by: `N=3` children settling to one assembled answer in index
order through the parent's door; `first_error` on child 2 cancelling child
3 with the answer reading it cancelled; the settlement test issuing a
projection and never the materialising listing; the refused-adapter case;
the conformance suite passing on the Ecto adapter; V03 up and down; the
full `mix quality` gate green.

### Key Discoveries:

- `Linkage.child_run_id/3` (`run/linkage.ex:147-151`) is deterministic in
  the index, so "does child k exist" never needs a jsonb query, and
  at-least-once re-drive is answered by `insert_run/2`'s `:run_exists`.
- `create_child/5` (`driver.ex:913-935`) already parameterises everything
  except the index: extracting the index is a one-line change to its body.
- A **private** `start_child/3` already exists at `driver.ex:852`, so the
  public door needs a distinct name. This plan uses `start_child_at`.
- `Serialization.with_run/3` (`serialization.ex:29`) is the exclusion
  primitive `Runs` itself uses (`runs.ex:578`), so a settlement section can
  take the parent's exclusion the same way without new surface.
- `Storage.update_run_status/4` (`storage.ex:353`) carries both blobs
  forward verbatim and is already the writer for a terminal transition with
  no `MachineState` in hand - the right place to write an outcome payload.
- ADR-0008's sp-3n2 amendment (`docs/adr/0008-*.md:250`) fixes the child
  side of the contract: an ordered set read by item index (`:275-276`), one
  child as the N=1 case (`:306-313`), the index durably on the child
  (`:311`), and no join table (`:330`). This plan implements all four.
- ADR-0006 decision 4 (`docs/adr/0006-*.md:113-124`) leaves the metadata
  index to the host; the campaign's ruling C6 ships one, so that decision
  gains a dated Note in this change rather than a silent contradiction.
- ADR-0006 decision 2 admits **identities only** into `metadata`. A child's
  outcome payload is not an identity, which is why it is a blob column and
  not a jsonb one: blob columns are what `:blob_type` encryption reaches
  (`ecto.ex:51-53`), and a donedata payload can carry anything the chart's
  author put in it.

## What We're NOT Doing

- **Not storing the child set on the parent.** The campaign's ruling
  R31-10 (taken 2026-09-05) makes the set derived from the children, and
  this plan derives it. That is not in tension with ADR-0008: the
  amendment's point 1 names the ordered set as the *logical* parent-side
  view whose "concrete encoding is the implementation plan's, not this
  record's", and the record's own later Note (2026-09-01, sp-21o,
  `docs/adr/0008-durable-subchart-child-runs.md:404-435`) says outright
  that there is no shipped `active_invocations` entry to widen and that
  "today that view is derived from the children rather than stored on the
  parent". The ruling picks the encoding the record left open; nothing
  needs reconciling.
- **No scheduling.** No cap, no queue bound, no job of any kind: those are
  statifier_oban's (sob-q3y). This package never enqueues anything and
  gains no dependency on statifier_oban.
- **No slices and no refill.** All N children are started by the scheduler
  up front (ruling: no slices).
- **No new query surface beyond the indexed projection.** No ranges, no
  ordering guarantees, no cursor: `list_runs_by_metadata/2`'s
  equality-on-all-pairs contract is unchanged, and the projection is the
  same match with fewer columns.
- **No measurement.** The settlement-read cost versus N is `sp-461`.
- **No `max_concurrency` handling.** That is sob's Note (ruling C7).
- **Not changing single-child durable subcharts.** A linkage with no
  `child_count` key is not a fan-out and keeps today's direct answer to
  the parent's door, byte for byte.

## Implementation Approach

Bottom-up, so every phase leaves the gate green on its own: the linkage
first (it is pure data), then the migration that makes the storage widening
possible, then the storage widening itself with its conformance cases, then
the public start door, then the settlement routing that consumes all of it,
then the records.

The settlement section is deliberately *not* nested inside the parent's
door. It takes the parent's exclusion, decides, releases it, and then
answers through the ordinary `done_invocation/5`, which takes the exclusion
itself. Two concurrent last-settlements can both decide "all N terminal";
the second one's answer is discarded by the existing spec 6.4.3 read
(`late_answer/3`, `driver.ex:660`), which is the mechanism this package
already relies on for exactly this race.

---

## Phase 1: Linkage carries `child_count` and the policy

### Overview

`Run.Linkage` gains two optional values under the reserved key, and the
predicate that says whether a child is part of a fan-out.

### Changes Required:

#### 1. The linkage struct

**File**: `lib/statifier_persistence/run/linkage.ex`
**Changes**: two new fields, `child_count` and `policy`, both `nil` by
default and both **absent from the metadata map when `nil`**, so an
ordinary durable subchart's stored linkage is byte-identical to today's.
`new/4` keeps its arity and meaning; `new/6` takes the two extra values.
`from_metadata/1` reads them when present and tolerates their absence.
`fan_out?/1` is `child_count != nil`.

```elixir
@enforce_keys [:parent_run_id, :invoke_id, :child_index, :content_hash]
defstruct [
  :parent_run_id,
  :invoke_id,
  :child_index,
  :content_hash,
  child_count: nil,
  policy: nil
]

@type policy :: :all | :first_error

def new(parent_run_id, invoke_id, child_index, content_hash)
def new(parent_run_id, invoke_id, child_index, content_hash, child_count, policy)

def fan_out?(%__MODULE__{child_count: nil}), do: false
def fan_out?(%__MODULE__{}), do: true
```

The policy is an atom in the struct and a string in the metadata map
(`"all"` / `"first_error"`), mapped by two explicit clauses in each
direction - no `String.to_atom/1`, no dynamic atom creation. A stored
`child_count` that is not a positive integer, or a policy string that is
neither of the two, makes `from_metadata/1` answer `:no_linkage`, which is
the existing arm for a malformed reserved map.

The moduledoc's "`child_index` is `0` for every child this version
creates" paragraph is replaced by the fan-out shape and cites the sp-3n2
amendment.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`)
- [ ] `test/statifier_persistence/run/linkage_test.exs` covers: round trip
      with and without the two new values; the omitted-when-nil metadata
      shape equals today's map exactly; `fan_out?/1` both ways; both policy
      spellings; a malformed `child_count` and a malformed policy each
      answering `:no_linkage`
- [ ] Every new test is sabotaged (break the code, confirm red, revert,
      note the mutation in one line above the test)

#### Manual Verification:
- [ ] The stored metadata for a single-child subchart is unchanged against
      a run created before this change

---

## Phase 2: V03 - the GIN index and the outcome column

### Overview

A third migration version: a `jsonb_path_ops` GIN index on the runs
table's `metadata`, and a nullable outcome-payload blob column.

### Changes Required:

#### 1. The migration

**File**: `lib/statifier_persistence/ecto/migrations/v03.ex` (new)
**Changes**: `up/1` adds the column and creates the index; `down/1` drops
both in reverse order. The column is a blob column so `:blob_type`
encryption reaches it, which is why it is not `jsonb`: a donedata payload
is not an identity in ADR-0006 decision 2's sense.

```elixir
def up(%Config{} = config) do
  runs = Config.table(config, :runs)

  alter table(runs, prefix: config.prefix) do
    add(:outcome_blob, :binary, null: true)
  end

  create(
    index(runs, ["metadata jsonb_path_ops"],
      using: "GIN",
      name: :"#{runs}_metadata_gin_index",
      prefix: config.prefix
    )
  )

  :ok
end
```

#### 2. The version map

**File**: `lib/statifier_persistence/ecto/migrations.ex`
**Changes**: `@current_version 3` and `3 => ...V03` in `@migrations`
(`:52-58`). The moduledoc's `from:` example keeps working unchanged.

#### 3. The generated schema

**File**: `lib/statifier_persistence/ecto.ex`
**Changes**: `outcome_blob: :binary` joins the `runs:` field list
(`:65-76`) and `@blob_columns` (`:53`), so the configured `:blob_type`
substitutes for it exactly as it does for the other three.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] The migration test migrates V01 -> V03 and rolls V03 -> V01 back on a
      real Postgres, asserting the column exists after `up` and is gone
      after `down`, and that the index exists by name (`pg_indexes`)
- [ ] `up(from: 3)` on an already-V02 database adds only V03
- [ ] `validate_version!/2` accepts 3 and rejects 4

#### Manual Verification:
- [ ] `EXPLAIN` on the containment query shows the GIN index in use on a
      table large enough for the planner to prefer it (this is `sp-461`'s
      measurement; here it is an eyeball, not a gate)

---

## Phase 3: The adapter widening

### Overview

The run record grows the outcome payload; the behaviour grows two optional
callbacks - "can you store an outcome?" and the indexed status projection;
both adapters implement them; the facade exposes them; the conformance
suite tests them.

### Changes Required:

#### 1. The behaviour

**File**: `lib/statifier_persistence/storage/adapter.ex`
**Changes**:

- `run_record` (`:78-86`) gains `outcome_blob: binary() | nil`.
- `update_run/2`'s doc gains a **second** carry-forward exception beside
  `metadata`'s: a record whose `outcome_blob` is `nil` leaves the stored
  value untouched; a binary sets it. The payload is written once, at the
  child's completion, and never cleared, so "nil means unchanged" is total.
- `error()` gains `:run_outcome_unsupported` and `:run_states_unsupported`.
- Two optional callbacks:

```elixir
@callback supports_run_outcome?(opts()) :: boolean()

@type run_state :: %{
        run_id: run_id(),
        status: run_status(),
        child_index: non_neg_integer() | nil
      }

@callback list_run_states_by_metadata(opts(), metadata()) ::
            {:ok, [run_state()]} | {:error, error()}
```

`list_run_states_by_metadata/2` answers the same match
`list_runs_by_metadata/2` answers, projecting three values and **no
blobs**. `child_index` is read out of this package's own reserved linkage
namespace, which is the only namespace either callback's match map ever
names; it is `nil` for a matched run that carries no linkage.

#### 2. The Ecto adapter

**File**: `lib/statifier_persistence/storage/ecto.ex`
**Changes**: `to_run_record/1` returns `outcome_blob`; `insert_run/2` and
`update_run/2` write it, `update_run/2` carrying the stored value forward
when the given one is `nil` (the same shape its `metadata` clause already
uses); `supports_run_outcome?/1` returns `true`;
`list_run_states_by_metadata/2` is the containment query with a
`select:` of `run_id`, `status` and a `fragment` extracting `child_index`
from the reserved key, so no blob column is read.

#### 3. The in-memory adapter

**File**: `lib/statifier_persistence/storage/in_memory.ex`
**Changes**: the same three, over the map it already holds.

#### 4. The facade

**File**: `lib/statifier_persistence/storage.ex`
**Changes**:

- `run_record/6` builds the new field (`nil` on every existing path).
- `update_run_status/4`'s `opts` gains `outcome_blob:` (default `nil`),
  which is the only writer of a payload. Its "carries every other stored
  field forward verbatim" promise is unchanged for every caller that does
  not pass it.
- `run_outcome_supported?/1` and `run_states_supported?/1`, the
  `function_exported?/3` predicates matching `child_listing_supported?/1`
  (`:405-409`).
- `list_run_states_by_metadata/2`, delegating when supported and answering
  `{:error, :run_states_unsupported}` otherwise, matching
  `list_runs_by_metadata/2`'s own refusal shape (`:423-431`).

#### 5. Conformance

**File**: `lib/statifier_persistence/testing/storage_conformance.ex`
**Changes**: mirroring the existing opt-in-by-export block at `:400-446`:
an outcome round-trip case (insert with `nil`, update with a binary, fetch
it back byte-identical, update again without one and confirm it survived)
and a projection case (three children under one invocation match, the
projection returning their ids, statuses and indices and no blobs).
Adapters that export neither callback are unaffected.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] Conformance passes for both the in-memory and the Ecto adapter
- [ ] A unit test asserts the projection's rows carry no `position_blob`
      key at all
- [ ] A unit test asserts an ordinary `update_run/5` (a step) leaves a
      previously written `outcome_blob` intact
- [ ] Every new test sabotaged

#### Manual Verification:
- [ ] An adapter written before this change still compiles and passes
      conformance with no edit (checked by reading the optional-callback
      guards)

---

## Phase 4: `Driver.start_child_at/6`

### Overview

The public start-with-index door, and the refusals that go with it.

### Changes Required:

#### 1. The public function

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `create_child/5` (`:913-935`) takes the index, the count and
the policy instead of hard-coding `child_index = 0`; the existing private
path passes `0, nil, nil` and is unchanged in behaviour. The new public
door:

```elixir
@spec start_child_at(
        driver :: t(),
        parent_run_id :: Runs.run_id(),
        effect :: Invoke.t() | {:start_child, Invoke.t(), {:invoke, Invoke.t()}},
        index :: non_neg_integer(),
        count :: pos_integer(),
        opts :: [policy: Linkage.policy()]
      ) :: :ok | {:refused, term()}
def start_child_at(driver, parent_run_id, effect, index, count, opts \\ [])
```

It builds the same `dispatch_context` shape the private path receives
(`run_id` and `invoke_id`, the latter off the effect), then runs the same
`resolve -> identify -> create` chain with the index, count and policy
threaded through. `index >= count` raises `ArgumentError` - a caller bug,
not a storage event, the same posture `metadata_opt!/1` takes.

The refusal at open grows: alongside `child_listing_supported?/1` it
requires `run_outcome_supported?/1` and `run_states_supported?/1`,
refusing `:run_outcome_unsupported` / `:run_states_unsupported`. Those two
checks apply to `start_child_at/6` only - the single-child path is
unchanged, because a subchart that never settles needs neither. All three
refusals funnel through the existing single `report_refusal/2` return, so
the `[:statifier_persistence, :child, :refused]` event still has one
emission site.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] Driver tests: `start_child_at/6` creates child `i` at the id
      `Linkage.child_run_id/3` derives, with `child_count` and the policy
      in its stored linkage; a second call for the same index adopts rather
      than duplicating (`:run_exists`); both new refusals fire for an
      adapter missing the respective callback; `index >= count` raises
- [ ] A test asserts the single-child `<invoke>` path's stored metadata is
      unchanged (no `child_count`, no policy)
- [ ] Every new test sabotaged

#### Manual Verification:
- [ ] The public spec reads the way `sob-q3y` was told it would (compare
      against the dated note on this bead)

---

## Phase 5: Settlement

### Overview

Route a fan-out child's completion to a settlement section instead of the
parent's door; persist its payload; test all-N by the projection under the
parent's exclusion; assemble once; answer once; cancel on `first_error`.

### Changes Required:

#### 1. Routing

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `maybe_answer_parent/3` (`:568`) keeps its two arms and gains
one decision inside `auto_answer_parent/3` (`:581`): a linkage for which
`Linkage.fan_out?/1` is true goes to `settle_child/4` instead of
`resolve_and_answer/4`. Everything else - no linkage, no resolver, an
active run - is untouched.

#### 2. The settlement section

```elixir
defp settle_child(driver, linkage, child_run_id, payload) do
  with :ok <- record_outcome(driver.store, child_run_id, payload),
       {:ok, decision} <- decide(driver, linkage) do
    case decision do
      {:answer, donedata} -> answer_parent_once(driver, linkage, donedata)
      :not_yet -> :ok
    end
  end
end
```

- `record_outcome/3` writes the payload with
  `Storage.update_run_status/4`, `outcome_blob:` the `:erlang.term_to_binary/1`
  encoding of `{:done, donedata}` or `{:failed, failure}`, and the run's own
  current status and failure carried through unchanged. Encoding and
  decoding are one private pair in this module: the payload is an opaque
  blob to storage exactly as a position is.
- `decide/2` runs inside the parent's exclusion, taken through the
  driver's own serialization strategy - `strategy.with_run(config,
  linkage.parent_run_id, fun)`, the same call `Runs` makes at
  `runs.ex:578`. Inside it:
  1. `Storage.list_run_states_by_metadata/2` over
     `Linkage.invocation_match/2` - the projection, never the listing.
  The exclusion is held across the cancel work under `:first_error`,
  which is where the ruling puts it, and that is a real cost: a cascade
  over live siblings and a host-supplied canceller both run while the
  parent is locked. It is bounded by N and by the host's own callback,
  and the alternative - cancelling outside the exclusion - reopens the
  window where a sibling settles between the cancel and the decision.

  2. Under `:first_error`, when this child failed: `Runs.cascade_cancel/3`
     over the same match (live siblings), then `driver.child_canceller` with
     the indices in `0..count-1` that the projection did not return
     (unstarted siblings). A `nil` canceller is a no-op, and a canceller
     that errors fails the settlement rather than answering a list it
     cannot vouch for. Then re-read the projection.
  3. All N indices terminal? If not, `:not_yet`.
  4. If yes: read the N payloads once - `Storage.fetch_run/2` per index
     over the ids `Linkage.child_run_id/3` derives, which is a single-key
     read per child and needs no second listing - decode each, and build the
     dense list in index order. An index with no run record, or a run whose
     status is `:cancelled`, contributes the cancelled entry; a failed child
     contributes its failure entry.
- `answer_parent_once/3` answers through `respond_to_parent/3` with the
  assembled list as the donedata, `entry: :answer_parent`, **over a driver
  built on the parent's own machine**. That swap is not optional and is
  the one thing the single-child path already does that a naive settlement
  would drop: `resolve_and_answer/4` (`driver.ex:598-612`) fetches the
  parent record's `content_hash` and calls `driver.chart_resolver.(...)`
  before answering, because `Storage`'s identity guard checks the supplied
  machine against the *parent* run's stored identity. A fan-out child's
  chart is not its parent's, so answering with the child's driver would be
  refused with `{:identity_mismatch, _}` and the settlement could never
  deliver. The settlement therefore reuses the same resolve step, and a
  driver with no `chart_resolver:` settles nothing - the same no-op
  `auto_answer_parent/3` already is for one.

  A losing racer's answer is discarded by `late_answer/3`, unchanged. That
  discard is idempotent for a chart that transitions out of the invoking
  state on its answer, which the compiled fan-out block is (statifier_blocks
  ADR-0009 decision 3: one `<invoke>`, one `done.invoke.<block id>`
  transition); a chart that stays in the invoking state after answering is
  the case the driver's moduledoc already names as not idempotent, and it
  is no more and no less true here than for a single child.

The assembled entry shape is a map with string keys - `"index"`,
`"status"` (`"completed"` / `"failed"` / `"cancelled"`), and `"donedata"`
or `"failure"` - because it becomes chart-visible event data and the
package's other chart-facing payloads (`answer_event/3`, `:439`) already
use string keys.

#### 3. The cancel seam

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: a `:child_canceller` field on the struct, wired like
`:chart_resolver` in `new/1`, defaulting to `nil`:

```elixir
@type child_canceller ::
        (parent_run_id :: Runs.run_id(),
         invoke_id :: String.t(),
         unstarted_indices :: [non_neg_integer()] ->
           :ok | {:error, term()})
```

#### 4. Cascade reach

**File**: `lib/statifier_persistence/runs.ex`
**Changes**: none expected. `cascade_cancel/3` over an invocation match
already reaches every child of one invocation whatever its index, and its
`retained` tally already covers a child that settled before the cancel. If
the tests find a gap, the fix stays inside this phase and is listed in the
request's Provenance.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] `N=3` children complete out of order (2, 0, 1) and the parent receives
      exactly one `done.invoke` whose donedata is the three entries in index
      order
- [ ] The first two completions answer the parent's door zero times
- [ ] `policy: :first_error` with child 1 failing: child 2 is cancelled
      through the cascade, an unstarted child 2 is reported to the
      canceller by index, and both read `"cancelled"` in the answer
- [ ] A test asserts the settlement path calls the projection and not
      `list_runs_by_metadata/2` (a stub adapter that raises from the
      listing)
- [ ] `N=1` under a fan-out linkage settles through the same path and
      answers a one-entry list
- [ ] A single-child subchart (no `child_count`) still answers its parent
      directly with the child's own donedata - the regression guard for the
      shipped path
- [ ] The re-drive case: settling the last child twice (the crash-between-
      payload-write-and-decision shape) answers the parent once and the
      second attempt is discarded
- [ ] Every new test sabotaged

#### Manual Verification:
- [ ] Read the assembled donedata of a three-child fan-out in the test
      output and confirm an operator could tell from it which index failed
      and which was cancelled, without opening a child run

---

## Phase 6: Records and docs

### Overview

The dated Note on ADR-0006, the README's new public function, and the
changelog fragment.

### Changes Required:

#### 1. ADR-0006

**File**: `docs/adr/0006-optional-opaque-run-metadata.md`
**Changes**: a dated Note appended **after** decision 4's paragraph
(`:124`), recording that V03 now ships a `jsonb_path_ops` GIN index on the
column, why (the settlement projection and the cascade both issue the
containment query, and a host that never added an index paid a sequential
scan per settlement), and that a host wanting a different index still adds
its own. Decision 4's own text is not edited: the Note records what
changed around it. **Zero removed lines under `docs/adr/`.**

#### 2. README

**File**: `README.md`
**Changes**: the fan-out paragraph in the durable-subchart section:
`start_child_at/6`, the two linkage values, and the settlement contract in
three sentences. No scheduling claims - the scheduler is another package.

#### 3. Changelog fragment

**File**: `changelog.d/<something>.md`, in the directory's existing style.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes
- [ ] `git diff origin/main -- docs/adr/` shows zero removed lines
- [ ] A fragment exists under `changelog.d/`

#### Manual Verification:
- [ ] A cold reader of ADR-0006 sees decision 4 and the Note as consistent
      rather than contradictory (this is the direction review's call)

---

## Testing Strategy

### Unit Tests:

- `test/statifier_persistence/run/linkage_test.exs` - the widened struct,
  the omitted-when-nil metadata shape, `fan_out?/1`, the malformed arms.
- `test/statifier_persistence/storage/...` - the outcome round trip, the
  carry-forward on an ordinary update, the projection's columns, the two
  new refusals.
- `test/statifier_persistence/ecto/migrations_test.exs` - V03 up and down,
  the index by name, `from: 3`.
- `test/statifier_persistence/driver/...` - `start_child_at/6`'s creation,
  adoption, refusals and argument guard; the settlement's ordering,
  once-only answer, `first_error` cancel of both kinds, the projection-only
  read, `N=1`, and the single-child regression guard.
- Conformance cases run against both adapters by the existing case
  template.

Every test that asserts `lib/` behaviour is sabotaged per the repo's
convention, with the mutation noted in one line above it.

### Manual Testing Steps:

1. Read the stored metadata of a single-child subchart created before and
   after this change and confirm it is identical.
2. `EXPLAIN` the containment query on a populated table and confirm the GIN
   index is chosen.
3. Read ADR-0006's decision 4 and its new Note together.

## References

- Bead: `sp-t57` (mirrors `sob-q3y` in statifier_oban)
- Records: `docs/adr/0006-optional-opaque-run-metadata.md` (decisions 2, 3,
  4), `docs/adr/0008-durable-subcharts.md` (decisions 2, 5, 7 and the
  sp-3n2 amendment), `docs/adr/0004-run-lifecycle-executor-seam-and-serialization.md`
  (decisions 2, 5, 6),
  `docs/adr/0002-configurable-keys-and-table-names.md` (decision 3, the
  versioned migrations)
- Similar implementation: the single-child path,
  `lib/statifier_persistence/driver.ex:852-995`
- The exclusion primitive: `lib/statifier_persistence/runs.ex:552-590`

## Unattended verification pass (2026-09-05)

`/wurk:verify --unattended` on the finished branch. The plan carried no
Deferred Manual Verification section (the phases were driven directly, so
no `--loop` wrote one), and an empty backlog is not a pass: every
acceptance criterion on `sp-t57` and every phase's Manual Verification
item was machine-checked against the branch instead. No human-confirmed
marker is written by this pass.

### The bead's acceptance criteria

**Machine-checked (unattended, 2026-09-05):** N=3 children settle to one
assembled answer in index order through the parent's door - the
`settlement` block's "N=3 settle to one assembled answer in index order"
test, which finishes the children in the order 2, 0, 1 and asserts the
three entries at positions 0, 1, 2. Sabotaged three ways (the
`answer_parent/3` routing clause, `entry/5`'s payload decode, and
`assemble/4`'s ordering), each red.

**Machine-checked (unattended, 2026-09-05):** `first_error` on a child
cancels the remaining one and the answer reads it cancelled - the
"first_error cancels a live sibling" test (child 1 fails, child 2's live
run is cancelled by the cascade and reads `"cancelled"`, and its stored
record's status is `:cancelled`), and the "reports the never-started
indices" test for the other kind (index 2 never started, reported to the
seam as `[2]`, reads `"cancelled"` in the same list).

**Machine-checked (unattended, 2026-09-05):** the count test never lists -
the "asks the projection and never the listing" test runs two settlements
against `RaisingListingAdapter`, whose `list_runs_by_metadata/2` raises.
Scoped deliberately to the settlements that answer nothing: the parent's
exit from the invoking state cascades a cancel, and that legitimately
walks records (ADR-0008 decision 5).

**Machine-checked (unattended, 2026-09-05):** the refused-adapter case -
the "refuses at open on a store that could not settle" test covers all
three arms (`:child_listing_unsupported`, `:run_outcome_unsupported`,
`:run_states_unsupported`) and asserts no child run was created in each.

**Machine-checked (unattended, 2026-09-05):** conformance passes on Ecto -
`test/statifier_persistence/storage/ecto_conformance_test.exs` and the
blob-typed variant both green, including the two new cases. The
`no_metadata` and `no_lock` conformance suites are green with their
adapters unmodified (`git diff origin/main` touches neither file), which
is the "an adapter written before this change is conformant unchanged"
item from phase 3.

**Machine-checked (unattended, 2026-09-05):** V03 up and down -
`migrations_test.exs` migrates V01 through V03 up in `setup_all` and back
down in `on_exit`, and two consecutive runs are green. A `down` that left
the index or the column behind would fail the second run's `up`.

**Machine-checked (unattended, 2026-09-05):** fragment present -
`changelog.d/sp-t57.md`.

**Machine-checked (unattended, 2026-09-05):** full gate green - bare
`mix quality`, 379 tests, 94.3% coverage, dialyzer and credo clean.

**Not applicable to an agent:** neither half of the mirrored pair closes
without the operator's word. Both remain open; the second dated note on
`sp-t57` records the shipped contract for `sob-q3y`.

### The phases' Manual Verification items

**Machine-checked (unattended, 2026-09-05):** a single-child subchart's
stored metadata is unchanged - `run_linkage_test`'s "a non-fan-out
linkage stores exactly the four keys it always has" asserts the map
literally, and `driver_fanout_test`'s "the single-child subchart path
records neither value" asserts it end to end through a real drive.

**Machine-checked (unattended, 2026-09-05):** the GIN index serves the
containment query - `EXPLAIN` on `statifier_runs` for
`metadata @> $1::jsonb` yields `Bitmap Index Scan on
statifier_runs_metadata_gin_index` with the `@>` predicate as its `Index
Cond`. The default plan on the empty test table is a sequential scan,
which is the planner being right about a zero-row table, so the check was
taken with `enable_seqscan = off`. Cost at volume is `sp-461`, not this
bead.

**Machine-checked (unattended, 2026-09-05):** the public spec reads the
way `sob-q3y` was told - compared against the first dated note on the
bead. Two deltas, both now recorded in a second dated note: the
`:run_not_found` refusal for a parent id naming no stored run, and the
`ArgumentError` for an out-of-range index being raised by
`Linkage.new/6` rather than repeated in `start_child_at/6`.

**Machine-checked (unattended, 2026-09-05):** the assembled donedata is
legible - the three-entry list in the N=3 test names the index, the
status, and either the donedata or st-ADR-0068's own three failure keys
per entry, so a failed or cancelled item is identifiable without opening
a child run.

**Deferred to the direction review:** whether a cold reader of ADR-0006
sees decision 4 and the new Note as consistent rather than contradictory.
That is a record-decision judgment and the docs/adr/ review gate's call,
not an agent's.

### Defects this pass found and fixed

None. The two defects this bead's own sabotage discipline caught were
fixed before their phases were committed, and both are worth naming here
because neither was visible from the tests alone: a settlement that
recursed through `answer_parent/3` without terminating, and a `settled?/3`
arm that no test distinguished (the `:all` policy with a child whose start
job had not run yet), for which a test was added.
