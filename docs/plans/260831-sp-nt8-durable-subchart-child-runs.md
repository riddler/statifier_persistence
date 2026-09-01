# Durable subchart child runs Implementation Plan

## Overview

Implement ADR-0008 (accepted, `docs/adr/0008-durable-subchart-child-runs.md`):
a durable `<invoke>` of a subchart creates the child as an ordinary run,
linked to its parent through a reserved, package-owned namespace inside run
`metadata`; the parent rests at quiescence with the invocation live; the child
answers through ADR-0007's existing public doors; and a parent that leaves the
invoking state cascades a retaining, idempotent cancel through the whole
subtree. Bead: sp-nt8 (mirrors sb-2i04).

## Current State Analysis

The durable stack has every piece this needs except the one clause that starts
a child.

- `StatifierPersistence.Driver` (`lib/statifier_persistence/driver.ex`) drives
  a run to quiescence and hands every `{:invoke, %Invoke{}}` effect to the
  host's `dispatch` fun (`driver.ex:512-530`). The fun answers `{:ok,
  donedata}`, `{:error, failure}`, or `:pending` (ADR-0007 decision 1). Its
  moduledoc still says durable subcharts are out of scope
  (`driver.ex:81-86`) - that sentence is what this work deletes.
- `Driver.done_invocation/5` and `failed_invocation/5` (`driver.ex:357-392`)
  are the public re-entry doors, and `late_answer/3` (`driver.ex:420-426`)
  takes the 6.4.3 liveness read *inside* the run's serialization strategy via
  `Runs.step/5`'s event-builder arm (`runs.ex:80`, `runs.ex:300-321`). This is
  the mechanism ADR-0008 decision 5 requires for dropping a late completion,
  and it needs no change.
- `Runs.create/4` already takes `metadata:` (ADR-0006) and refuses at open
  through `Storage.check_metadata/2` (`runs.ex:167`). `Storage.insert_run/5`
  validates only the shape (string keys) and stores the map opaquely
  (`storage.ex:436-451`).
- `Runs.fail/4` (`runs.ex:249-270`) is the existing host-driven terminal
  transition, and it is the exact shape cancel needs: one serialized
  `Storage.update_run_status/4`, position untouched, terminal runs discarded.
- The `runs.status` column is `:text, null: false` with no check constraint
  (`lib/statifier_persistence/ecto/migrations/v01.ex:69`), so a fourth status
  value needs **no migration**. Only the `@statuses` map
  (`lib/statifier_persistence/storage/ecto.ex:57`) has to learn it.
- `Statifier.Effect.Done` carries `donedata`
  (`deps/statifier/lib/statifier/effect/done.ex`), but `Runs` splits `:done`
  off as a lifecycle effect and consumes it into status only
  (`runs.ex:526-529`, `runs.ex:547-554`). Donedata reaches no caller today.
- The Ecto adapter already has `list_runs_by_metadata/2`
  (`storage/ecto.ex:312-329`), a `jsonb` containment query - but it is a
  module-local public function, not an `Adapter` callback, and `InMemory` has
  no equivalent.

What is missing: nothing on the durable path ever produces or consumes a
`{:start_child, ...}` instruction, no run knows it has a parent, and there is
no fourth status arm.

### Where `{:start_child, ...}` reaches the Driver

This is the one point the ADR states in upstream vocabulary and the plan has
to resolve concretely, so it is recorded here as a decision rather than left
implicit.

`{:start_child, invoke, {:invoke, invoke}}` is a `Statifier.Session.Effects`
**instruction**, not an effect
(`deps/statifier/lib/statifier/session/effects.ex:169`). The durable path
never calls `Session.Effects.plan/2` at all - `Runs.persist_tail/6` hands the
core's raw effect list straight to the executor (`runs.ex:376-379`) - so no
instruction can arrive through the effect list.

The sibling record settles where it does arrive. statifier_blocks ADR-0008
decision 4 says the durable subchart module "contributes a **dispatch-time
answer**", through "`StatifierPersistence.Driver`'s dispatch fun ... not a
per-session handler module registered under st-ADR-0051". So the instruction
is what the **`dispatch` fun returns**: a fourth arm beside `{:ok, donedata}`,
`{:error, failure}` and `:pending`. The `start_child` clause ADR-0008
decision 3 asks for is the clause in `Driver.perform/5` that matches that
return, and "answers `:pending`" is exactly what it does after creating the
child - nothing is buffered, and the parent reaches quiescence with the
invocation live.

`invoke.content` on that tuple is SCXML markup, a binary
(`statifier_blocks/lib/statifier_blocks/runtime/subchart.ex:190` returns
`%{invoke | content: scxml}`), which `Statifier.Invoke.Source.resolve/2`
compiles (`deps/statifier/lib/statifier/invoke/source.ex:78-83`). The Driver
uses that function rather than compiling itself, so the durable path resolves
a child exactly as `Statifier.Session` does.

## Desired End State

A host wiring `dispatch:` to a durable subchart handler can run a chart whose
`<invoke type="statifier_blocks:subchart">` starts a child that:

- exists as an ordinary run with its own `run_id`, guarded by the same content
  hash on every load, advancing through the same `Runs` loop;
- carries `parent_run_id`, `invoke_id`, `child_index` and a mandatory pin of
  its own chart identity in one reserved metadata key;
- leaves the parent at rest with the invocation live in `active_invocations`;
- answers the parent through `Driver.done_invocation/5` /
  `failed_invocation/5` and no other channel;
- is cancelled - along with its own children, recursively, idempotently, with
  every record retained under the terminal status `:cancelled` - when the
  parent leaves the invoking state;
- and whose late completion, arriving on a node that never saw the invocation
  live, is dropped by ADR-0007 decision 3's existing mechanism.

Verified by: the full `mix quality` gate green, the two named restart-race
cases in `test/statifier_persistence/driver_restart_race_test.exs` passing,
and every generated storage-conformance case green for both shipped adapters.

### Key Discoveries:

- `Driver.perform/5` (`driver.ex:512`) is the only place a dispatch answer is
  read; a fourth arm is additive and every existing host is unaffected.
- `Runs.fail/4` (`runs.ex:249`) is a working template for a machine-free
  terminal write: `Storage.update_run_status/4` (`storage.ex:328-333`) carries
  both blobs forward verbatim, so cancelling a run needs **no compiled
  `Machine`**. This is what makes a cascade across charts the parent's driver
  has never seen possible at all.
- Conversely, *answering* a parent needs the parent's compiled `Machine`, and
  this package cannot produce one: `chart_blob` is opaque by ADR-0003
  decision 1 and nothing here decodes it. The parent chart therefore has to
  come from the caller - see Phase 4's `chart_resolver:`.
- `runs.status` has no check constraint (`v01.ex:69`), so the fourth status
  arm ships without a migration.
- ADR-0004 decision 3's at-least-once effect execution means a crash between
  the child create and the parent's persist re-drives the same step and
  re-runs the same `start_child`. A *deterministic* child run id makes that
  re-drive idempotent for free, because the second create hits the adapter's
  atomic `:run_exists` refusal (`adapter.ex:188-198`).
- `Statifier.Session.Invocations.seed_datamodel/2`
  (`deps/statifier/lib/statifier/session/invocations.ex:220-232`) is public and
  is how `Statifier.Session` seeds a child's datamodel from `invoke.params`;
  the durable child seeds the same way through
  `Runs.create/4`'s `initialize:` option, which reaches
  `Statifier.MachineState.new/2` unchanged (`interpreter.ex:261-264`).

## What We're NOT Doing

- **Fan-out (an invocation mapping to N children).** ADR-0008 decision 7 is a
  hard carve-out from the operator: designed for, deliberately not built. The
  linkage carries a `child_index` and every child lookup is an enumeration
  rather than a single-key read precisely so nothing here *assumes* one child
  per invocation, but no fan-out planning, no aggregation vocabulary, and no
  partial-failure policy is written.
- **A runtime ancestry list or depth ceiling.** See "Nesting guard" under
  Implementation Approach - decided against, with reasons.
- **A join table or a first-class linkage column.** ADR-0008 decision 2 admits
  one only if the queries force it, and they do not: the two queries are "find
  my parent" (one key read off the child's own metadata) and "find my
  children" (one metadata-containment query the Ecto adapter already
  implements).
- **A migration.** The status column is free-form text.
- **Any edit to `docs/adr/0008-durable-subchart-child-runs.md`, `README.md`,
  or CI workflow files.** Sibling beads are queued behind this one on README
  and CI.
- **Deleting `statifier_examples`' `durable_subchart_unsupported` refusal.**
  That is that repo's own bead (statifier_blocks ADR-0008, Consequences).
- **A `stop_child` / `forward` durable counterpart.** statifier_blocks
  ADR-0008 decision 4 states the durable module offers neither, and a durable
  cancel happens through the cascade, not through an instruction.

## Implementation Approach

Six phases, ordered so that each one leaves the full gate green on its own:
the storage surface first (it is what everything else writes through), then
the linkage vocabulary, then the executor clause that creates a child, then
the completion path, then the cascade, then the two named race tests.

**The terminal-status word is `:cancelled`.** Reasons, in order of weight:
(1) it is the word ADR-0008 decision 5 uses for the operation itself ("cancel
cascades", "a cancelled subtree") and the word this codebase already uses in
prose throughout - `Driver`'s moduledoc says "a cancelled invocation's answer"
(`driver.ex:117`) and "An invocation the chart cancels" (`driver.ex:106`) - so
the status reads as the noun of the verb the record already chose, with the
same double-`l` spelling the surrounding files use;
(2) `:abandoned` is taken: `Runs.fail/4`'s own docstring is "Abandons a run"
and it produces `:failed` (`runs.ex:234-245`), so reusing the word would name
two different terminal states;
(3) `:stopped` and `:terminated` both connote a process ending, and a durable
run is precisely the thing that holds no process.
Blast radius, all of it in Phase 1: `Adapter.run_status`
(`adapter.ex:48`), the Ecto `@statuses` map (`storage/ecto.ex:57`), the two
`status in [:completed, :failed]` terminal guards (`runs.ex:221`,
`runs.ex:259`), and the conformance harness.

**The nesting guard: none.** ADR-0008 decision 6 leaves a runtime ancestry
list or depth ceiling explicitly open, and this plan decides **against
adding either**, for three reasons. First, the bound the record names -
the resolver's `cycle_refused` - is a real bound on the *document* graph, and
it is the only one the record relies on. Second, the refusal set is closed at
four (statifier_blocks ADR-0008 decision 5), and a depth-exceeded refusal
would need a fifth reason that record forbids; folding it into
`child_run_creation_failed` would say storage failed when it did not. Third,
the property the cascade actually needs - that recursion terminates - is
guaranteed by construction here rather than by a counter: a child run id
strictly extends its parent's (see the derivation below), so the run tree is
acyclic and finite whatever the document graph does. A ceiling would be a
configuration knob with no evidence for a value. Reopener: if a host reports a
runaway subtree that `cycle_refused` did not catch, a depth ceiling is the
answer and it changes no contract in ADR-0008.

**The child run id is derived, not host-supplied.** ADR-0004 decision 2 says
`run_id` is "a caller-supplied opaque string ... not a surrogate this layer
generates", and a child run has no caller to supply one. The child's id is

    parent_run_id <> "/" <> invoke_id <> "/" <> Integer.to_string(child_index)

with `child_index` fixed at `0` today. This is the narrowest possible
narrowing of that decision - the id is still rooted in a caller-supplied key,
and every character after it is deterministic - and it buys three things at
once: idempotency across ADR-0004 decision 3's at-least-once re-drive
(`invoke_id` is a deterministic `MachineState` counter per st-ADR-0008, so the
re-drive computes the same id and the adapter's atomic `:run_exists` refusal
answers), acyclicity of the run tree (each id is strictly longer than its
parent's), and the reserved slot fan-out will need. No option to override it
is offered: a host-supplied generator could break both the idempotency and the
acyclicity, and neither is a property to leave to convention.

## Phase 1: The storage surface - `:cancelled` and child enumeration

### Overview

Teach the adapter contract, both shipped adapters, the run lifecycle and the
conformance harness about a fourth terminal status and about listing runs by a
metadata match. Nothing consumes either yet; both are exercised by their own
tests.

### Changes Required:

#### 1. The adapter contract

**File**: `lib/statifier_persistence/storage/adapter.ex`
**Changes**: `run_status` gains `:cancelled`; a new optional callback.

```elixir
@typedoc """
A run's lifecycle status (ADR-0004 decision 2, extended by ADR-0008
decision 5). `:completed`, `:failed` and `:cancelled` are terminal. ...
"""
@type run_status :: :active | :completed | :failed | :cancelled

@doc """
Optional metadata-match listing (ADR-0006 decision 3's equality-match
helper, promoted to a callback by ADR-0008 decision 5).

Lists the runs whose stored `metadata` contains every key/value pair in
`metadata`, recursively for a nested map. Equality match on all pairs is
the whole query surface ... Exporting it is how an adapter declares it can
answer "which runs name me as their parent", which is what a cascading
cancel walks; an adapter that does not export it cannot host a durable
subchart, and `StatifierPersistence.Driver` refuses at open rather than
starting a child it could never cancel.
"""
@callback list_runs_by_metadata(opts(), metadata()) ::
            {:ok, [run_record()]} | {:error, error()}

@optional_callbacks isolate: 1, lock_run: 3, supports_metadata?: 1,
                    list_runs_by_metadata: 2
```

#### 2. The Ecto adapter

**File**: `lib/statifier_persistence/storage/ecto.ex`
**Changes**: add `cancelled: "cancelled"` to `@statuses` (line 57); mark the
existing `list_runs_by_metadata/2` with `@impl Adapter` and keep its body and
docstring as they stand (the `jsonb` `@>` operator is already recursive
containment, so a nested reserved-namespace match works unchanged).

#### 3. The in-memory adapter

**File**: `lib/statifier_persistence/storage/in_memory.ex`
**Changes**: implement `list_runs_by_metadata/2` with the same
subset semantics and the same `ArgumentError` on an empty or
non-string-keyed map, over the Agent's `runs` map.

```elixir
@impl Adapter
@spec list_runs_by_metadata(Adapter.opts(), Adapter.metadata()) ::
        {:ok, [Adapter.run_record()]} | {:error, Adapter.error()}
def list_runs_by_metadata(opts, metadata) do
  validate_match!(metadata)

  runs =
    pid(opts)
    |> Agent.get(& &1.runs)
    |> Map.values()
    |> Enum.filter(&contains?(Map.get(&1, :metadata, %{}), metadata))

  {:ok, runs}
end

# Recursive containment, matching the Ecto adapter's `jsonb @>`: every pair
# in `match` is present in `stored`, and a map value contains rather than
# equals.
defp contains?(stored, match) when is_map(stored) and is_map(match) do
  Enum.all?(match, fn {key, value} ->
    case Map.fetch(stored, key) do
      {:ok, stored_value} when is_map(value) and is_map(stored_value) ->
        contains?(stored_value, value)

      {:ok, stored_value} ->
        stored_value == value

      :error ->
        false
    end
  end)
end
```

#### 4. The facade

**File**: `lib/statifier_persistence/storage.ex`
**Changes**: add `list_runs_by_metadata/2` and `child_listing_supported?/1`,
the `metadata_supported?/1`-shaped predicate over
`function_exported?(adapter, :list_runs_by_metadata, 2)`. The facade function
returns `{:error, :child_listing_unsupported}` for an adapter that does not
export it. Add `:child_listing_unsupported` to `Storage.error/0`.

#### 5. The run lifecycle

**File**: `lib/statifier_persistence/runs.ex`
**Changes**: both terminal guards learn the new arm, and `cancel/4` lands
beside `fail/4`.

```elixir
# runs.ex:221 and runs.ex:259
{:ok, %{status: status} = run_record}
when status in [:completed, :failed, :cancelled] ->
  {:discarded, Run.from_record(run_record)}
```

```elixir
@doc """
Cancels a run: the second host-driven terminal transition (ADR-0004
decision 6 as extended by ADR-0008 decision 5), and the one a cascading
cancel writes through.

Cancellation **retains**: no record and no position is deleted, no
interpreter is involved, and the stored position is left untouched - only
the record's status changes, to `:cancelled`. A run that is already
terminal - cancelled by an earlier, interrupted cascade included - is
discarded with `{:discarded, run}`, which is what makes re-running a
cascade over an already-cancelled subtree a no-op.

`opts` accepts `serialization:` only, exactly as `fail/4` does.
"""
@spec cancel(store :: Storage.t(), run_id :: run_id(), opts :: keyword()) ::
        {:ok, Run.t()} | {:discarded, Run.t()} | {:error, error()}
def cancel(%Storage{} = store, run_id, opts \\ []) do
  serialized(store, run_id, opts, fn -> cancel_tail(store, run_id) end)
end
```

`cancel_tail/2` mirrors `fail_tail/3` and calls
`Storage.update_run_status(store, run_id, :cancelled, failure: nil)`.

#### 6. The conformance harness

**File**: `lib/statifier_persistence/testing/storage_conformance.ex`
**Changes**: one new generated case, in the run-records section - a
`:cancelled` run record round-trips through `insert_run/2` and through
`update_run/2` with its `position_blob` unchanged. One new case, generated
only when the adapter exports `list_runs_by_metadata/2`, asserting the
containment semantics on a nested map and non-matching runs excluded.

#### 7. Tests and changelog

**Files**: `test/statifier_persistence/runs_test.exs`,
`test/statifier_persistence/in_memory_test.exs` (or the existing adapter
test file), `changelog.d/sp-nt8.md`.

Cases: `Storage.list_runs_by_metadata/2` returns
`{:error, :child_listing_unsupported}` for an adapter that does not export the
callback and delegates for one that does; `Storage.child_listing_supported?/1`
answers both ways (this pair matters for the gate's 90% coverage floor - the
facade additions need their own cases, not only the conformance ones);
`cancel/3` moves an `:active` run to `:cancelled` and leaves the stored
position byte-identical; `cancel/3` on an already-`:cancelled` run returns
`{:discarded, _}` and writes nothing; `step/5` on a `:cancelled` run is
discarded before any position decode; `fail/4` on a `:cancelled` run is
discarded.

Each case is sabotaged red first and carries its one-line mutation note, per
the repo convention. Concretely: for the discard cases, drop `:cancelled` from
the guard on `runs.ex:221`/`runs.ex:259`; for the retention case, pass
`position: :persist` with a fresh state instead of using
`update_run_status/4`; for the containment case, make `contains?/2` compare
with `==` instead of recursing.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (never `--profile loop`, never `--skip`).
- [x] `mix format` leaves no drift (the gate runs format in check mode).
- [x] The new conformance cases are generated and green for both
      `StatifierPersistence.Storage.InMemory` and
      `StatifierPersistence.Storage.Ecto` (the Ecto conformance test runs
      against Postgres).

#### Manual Verification:
- [ ] Every new test was confirmed red under its noted mutation before the
      revert. This is a process attestation, not a gate-checkable state - no
      command re-applies a mutation after the fact - so it belongs here and is
      the implementer's to affirm per the repo's sabotage convention.
- [ ] Reading `Adapter.run_status`'s typedoc, a third-party adapter author can
      tell that `:cancelled` is terminal and that no callback validates the
      transition.
- [ ] No `status in [...]` guard anywhere in `lib/` still lists only two
      terminal arms (grep for `:completed, :failed`).
- [ ] The changelog fragment reads as an effect on a user of the library, not
      as a description of the diff.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The reserved linkage namespace

### Overview

Add the package-owned metadata namespace ADR-0008 decision 2 grants, the
derivation of a child run id, and the guard that keeps a host from writing
into the reserved key. Nothing creates a child yet.

### Changes Required:

#### 1. The linkage module

**File**: `lib/statifier_persistence/run/linkage.ex` (new)
**Changes**: the whole vocabulary in one place, so exactly one module reads a
metadata key.

```elixir
defmodule StatifierPersistence.Run.Linkage do
  @moduledoc """
  A durable subchart child's parent linkage: the reserved, package-owned
  namespace inside a run's `metadata` (ADR-0008 decision 2).

  ADR-0006 decision 1 says this package never reads a metadata key to make
  a decision. ADR-0008 decision 2 narrows that, and narrows it exactly
  this far: linkage lives under one reserved top-level key, this package
  reads *only* that key, and everything outside it stays as opaque as it
  was - never read, never validated beyond shape, never merged into a
  blob. ADR-0006 decision 2 is untouched: every value here is an identity
  (a run id, an invocation id, a content hash) and never personal data.

  The stored shape, under `#{@reserved_key}`:

      %{
        "parent_run_id" => "run_42",
        "invoke_id" => "call",
        "child_index" => 0,
        "content_hash" => "sha256:..."
      }

  `content_hash` is the **mandatory** pin ADR-0008 decision 2 hardens into
  contract: the same hash `Statifier.Machine.identity/1` produces for the
  child's own chart, recorded a second time where the parent-child
  relationship can see it. A child is resumed by whatever node picks it up,
  and this is what stands between "resumed the workflow you started" and
  "resumed a different workflow that happens to share an id".

  `child_index` is `0` for every child this version creates. It is
  recorded anyway because ADR-0008 decision 7 requires the linkage not to
  *assume* one child per invocation; nothing here fans out.
  """
end
```

Public functions, all `@spec`'d:

- `reserved_key/0` - the one definition site for the namespace string,
  `"statifier_persistence"`.
- `new/4` (`parent_run_id`, `invoke_id`, `child_index`, `content_hash`) ->
  `%Linkage{}` struct.
- `to_metadata/1` -> the `%{reserved_key() => %{...}}` map, string keys and
  JSON-representable values only, so the Ecto adapter's `jsonb` check passes.
- `from_metadata/1` -> `{:ok, %Linkage{}} | :no_linkage` for a run whose
  metadata carries none. Not an `{:error, _}`: having no parent is an ordinary
  property of a run, not a failure.
- `child_run_id/3` (`parent_run_id`, `invoke_id`, `child_index`) -> the
  derivation, the single definition site of the id shape.
- `parent_match/1` (`parent_run_id`) -> the containment map a cascade queries
  with, `%{reserved_key() => %{"parent_run_id" => parent_run_id}}`.
- `invocation_match/2` (`parent_run_id`, `invoke_id`) -> the same, narrowed to
  one invocation, which is what a cancel of a single invocation walks.

#### 2. The reserved-key guard

**File**: `lib/statifier_persistence/runs.ex`
**Changes**: `create/4`'s `metadata:` handling refuses a caller map that
carries the reserved key, and a private `linkage:` option carries the
package's own.

```elixir
# A host writing into the reserved namespace collides with the package
# (ADR-0008, Consequences). The shape of `metadata:` is the one thing
# ADR-0006 decision 1 validates and a malformed option is a caller bug, so
# this raises rather than joining the error vocabulary - same posture as
# Storage.metadata_opt!/1.
@spec metadata([opt()]) :: Adapter.metadata()
defp metadata(opts) do
  supplied = Keyword.get(opts, :metadata, %{})

  if Map.has_key?(supplied, Linkage.reserved_key()) do
    raise ArgumentError,
          "the #{inspect(Linkage.reserved_key())} metadata key is reserved by " <>
            "statifier_persistence for durable subchart linkage (ADR-0008 " <>
            "decision 2) and cannot be supplied by a host"
  end

  case Keyword.get(opts, :linkage) do
    nil -> supplied
    %Linkage{} = linkage -> Map.merge(supplied, Linkage.to_metadata(linkage))
  end
end
```

`create/4`'s `Storage.check_metadata/2` call at `runs.ex:167` must see the
merged map, so the refusal-at-open still fires for an adapter that cannot
store metadata at all - a durable child on a metadata-less adapter is refused
before any effect runs, which is the same ordering ADR-0006 decision 3 set.

#### 3. Documentation of the `opt` type

**File**: `lib/statifier_persistence/runs.ex`
**Changes**: `@type opt` gains `{:linkage, Linkage.t()}` with a doc line
saying it is the package's own and that a host uses `metadata:`.

#### 4. Tests and changelog

**File**: `test/statifier_persistence/run_linkage_test.exs` (new),
`test/statifier_persistence/runs_test.exs`, `changelog.d/sp-nt8.md` (append).

Cases: `to_metadata/1` round-trips through `from_metadata/1`;
`from_metadata/1` answers `:no_linkage` for `%{}` and for a host map with
unrelated keys; `child_run_id/3` is stable for the same inputs and differs
when any input differs; `child_run_id/3` output strictly starts with the
parent id (the acyclicity property the cascade rests on); `to_metadata/1`'s
output is accepted by the Ecto adapter's `json_representable?/1` (assert via a
real `Storage.insert_run/5` against the Ecto adapter, in the Ecto test file);
`Runs.create/4` raises `ArgumentError` when a host supplies the reserved key;
`Runs.create/4` with `linkage:` stores the namespace and it reads back through
`Storage.fetch_run/2`.

Mutations for the sabotage notes: drop the `Map.has_key?` guard (the
`ArgumentError` case); return a fixed string from `child_run_id/3` (the
stability and prefix cases); have `from_metadata/1` return `{:ok, %Linkage{}}`
with defaults instead of `:no_linkage` (the no-parent case).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `Storage.insert_run/5` accepts a linkage map through the Ecto adapter -
      i.e. the reserved namespace is `jsonb`-representable, asserted by a real
      insert rather than by inspection.

#### Manual Verification:
- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] Exactly one module in `lib/` reads a metadata key (grep for
      `reserved_key` and for literal `"statifier_persistence"`), so ADR-0006
      decision 1's narrowing is as narrow as the record says.
- [ ] The moduledoc states the pin is mandatory and says why, in this
      package's own vocabulary rather than by citing the ADR alone.

**Implementation Note**: as Phase 1.

---

## Phase 3: The `start_child` clause on the Driver

### Overview

The executor clause ADR-0008 decision 3 asks for: a fourth `dispatch` return
arm, the child run created with its linkage under the parent's exclusion, and
`:pending` as the answer so the parent rests with the invocation live.

### Changes Required:

#### 1. The dispatch type

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `@type dispatch` gains the instruction arm, and the moduledoc's
"durable subcharts are deliberately out of scope here" paragraph
(`driver.ex:81-86`) is replaced by a durable-subchart section.

```elixir
@type dispatch ::
        (type :: String.t() | nil, params :: term(), context :: dispatch_context() ->
           {:ok, term()}
           | {:error, keyword()}
           | :pending
           | {:start_child, Invoke.t(), {:invoke, Invoke.t()}})
```

The typedoc gains the arm's meaning: *start this chart as the child of this
invocation*. It is `Statifier.Session.Effects`' own instruction, emitted
unchanged by `StatifierBlocks.Runtime.Subchart`
(`statifier_blocks/lib/statifier_blocks/runtime/subchart.ex:190`) and by the
built-in `Statifier.Invoke.Handler.Scxml`
(`deps/statifier/lib/statifier/invoke/handler/scxml.ex:33`); this driver
executes it where `Statifier.Session` executes it in-memory, which is what
makes a chart portable between the two. It is never renamed or reshaped.

#### 2. The clause

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `perform/5`'s `case dispatch.(...)` gains the arm. The clause
needs the driver itself (for `store`, `serialization` and `invoke_types`), so
`perform/5` takes the driver rather than the bare `dispatch` fun.

```elixir
# ADR-0008 decision 3. The child is created inside the parent's own
# serialization strategy - this runs in the executor, inside
# `Runs.persist_tail/6`, inside `with_run/3` - because a parent that
# believes it has a child and a child run that was never created is the
# window statifier_blocks ADR-0008 decision 4 names as the one that loses.
# The exclusion is per run id, and a child's id is not the parent's, so
# nothing nests on one key.
#
# The answer is `:pending` in every non-refusing case: nothing is buffered,
# the parent reaches quiescence, and the invocation rides the persisted
# position out to whatever answers it.
{:start_child, %Invoke{} = resolved, {:invoke, %Invoke{}}} ->
  case start_child(driver, resolved, context) do
    :ok -> :ok
    {:refused, detail} -> buffer(reader, ref, invoke, {:failed, refusal(detail)})
  end
```

`start_child/3`, in order:

1. **Refuse at open when the store cannot enumerate children.** If
   `Storage.child_listing_supported?/1` is false, refuse: a child that could
   never be found is a child that could never be cancelled, and starting one
   would break ADR-0008 decision 5. Same posture as ADR-0006 decision 3's
   refusal at open, and it happens before any write.
2. Resolve the child machine with `Statifier.Invoke.Source.resolve(resolved,
   [])` - `invoke.content` is SCXML markup and that function compiles it
   (`source.ex:78-83`). Any error arm refuses.
3. Refuse when `Statifier.Machine.identity/1` on the child machine is `nil`:
   the pin is mandatory, and a chart with no identity cannot be guarded on
   reload.
4. Build the linkage from the *parent's* `context.run_id`, the invocation's
   `invoke_id`, index `0`, and the child's own `content_hash`; derive the
   child run id.
5. `Runs.create(driver.store, child_run_id, child_machine, executor: ...,
   linkage: linkage, initialize: [datamodel:
   Statifier.Session.Invocations.seed_datamodel(resolved.params,
   child_machine)], serialization: ..., invoke_types: ...)`, driving the
   child to quiescence through this module's own loop so a child whose own
   initialization invokes gets the same treatment (that is decision 6's
   nesting, and it needs no extra code).
6. `{:error, :run_exists}` is **not** a failure. ADR-0004 decision 3's
   at-least-once execution means a crash between the create and the parent's
   persist re-drives this exact step; the id is deterministic, so the second
   create finds the first. Fetch the existing run, and if its linkage names
   this parent and this invocation, the child is already started - answer
   `:ok` (pending). If it names something else, refuse.
7. Any other error refuses.

Refusal is the failing dispatch arm and nothing new:
`buffer(reader, ref, invoke, {:failed, reason: "child_run_creation_failed",
detail: detail})`, which the existing `answer_event/3` turns into
`error.communication.invoke.<invoke_id>` with st-ADR-0068's three keys
(`driver.ex:568-576`). The spelling is `child_run_creation_failed`, snake_case,
exactly as statifier_blocks ADR-0008 decision 5 fixes it. `attempts` is left
absent - a refusal made no attempt - so it reads `:undefined`, matching the
in-memory handler.

#### 3. The child's driver

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: a child is driven by `%{driver | machine: child_machine}` -
the same store, the same serialization strategy, the same `effects` executor,
the same `dispatch` fun (which is what makes a grandchild work), a different
machine.

#### 4. Tests and changelog

**File**: `test/statifier_persistence/driver_subchart_test.exs` (new),
`changelog.d/sp-nt8.md` (append).

A parent chart with `<invoke id="call" type="myapp:subchart"/>` and a
timeout escape, plus a two-state child chart, both compiled in the test. The
`dispatch` fun returns `{:start_child, %{invoke | content: @child_source},
{:invoke, invoke}}`.

Cases: the child run exists under the derived id after the parent's create;
its metadata carries all four linkage values and the `content_hash` equals
`Machine.identity(child_machine).content_hash`; the parent is at rest with
`"call"` live in `active_invocations`, read back through
`Storage.load_run_position/3` and not from the return value; a second identical
drive (the at-least-once re-drive) does not create a second run and does not
refuse; an unresolvable `content` refuses with
`error.communication.invoke.call` whose `"reason"` is
`"child_run_creation_failed"`; a store whose adapter cannot enumerate children
refuses the same way and writes no child - this needs a **new** fixture beside
`test/support/no_lock_adapter.ex`, because that one also withholds
`lock_run/3` and so refuses at serialization before the child clause is ever
reached; the new one delegates to `InMemory` for everything including
`lock_run/3` and `supports_metadata?/1`, and withholds
`list_runs_by_metadata/2` alone; a child that itself invokes a grandchild produces a
three-run tree with each linkage naming its own parent (decision 6's nesting).

Mutations: return `:pending` without creating the run (the child-exists case);
drop the `content_hash` from the linkage (the pin case); treat `:run_exists`
as an error (the re-drive case); drop the `child_listing_supported?/1`
pre-check (the refuse-at-open case).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] Dialyzer accepts the widened `dispatch` type with no new warning and no
      suppression.

#### Manual Verification:
- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] The `Driver` moduledoc no longer says durable subcharts are out of
      scope, and the replacement section says who emits the instruction and
      who executes it.
- [ ] The refusal string is byte-identical to statifier_blocks ADR-0008
      decision 5's `child_run_creation_failed`.
- [ ] A host that never returns the new arm sees no behavior change anywhere.

**Implementation Note**: as Phase 1.

---

## Phase 4: Completion - donedata out, and the answer back to the parent

### Overview

A child that reaches a final state has to answer its parent through
ADR-0007's public doors, carrying its donedata. Two things are missing:
donedata reaches no caller today, and answering a parent needs the parent's
compiled `Machine`, which this package cannot derive from storage.

### Changes Required:

#### 1. Donedata on the host-facing run

**File**: `lib/statifier_persistence/run.ex`, `lib/statifier_persistence/runs.ex`
**Changes**: `Run` gains `donedata :: term() | nil`, set from the `:done`
lifecycle effect on the step that completed the run and `nil` on every other
step. `from_record/1` sets `nil` - a stored record carries no donedata,
because a position is not where it lives.

```elixir
# `{:done, %Done{donedata: donedata}}` is consumed into `:completed` status
# (ADR-0004 decision 6) and, from ADR-0008 decision 3, also surfaced: a
# durable subchart's parent is answered with its child's donedata, and this
# is the only moment it exists. It is deliberately not persisted - a
# position that has reached a final state has no configuration left to
# carry it, and inventing a column for it would make a run record a
# result store.
@spec done_effect([Statifier.Effect.t()]) :: term() | nil
```

#### 2. The parent-answering path

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: a new driver option and the automatic re-entry.

```elixir
- `chart_resolver:` - how this driver reaches a chart it does not hold:
  `(content_hash -> {:ok, Statifier.Machine.t()} | :error)`. It exists for
  exactly one purpose - answering a durable subchart's parent, whose chart
  is not this driver's `machine` (ADR-0008 decision 3). This package cannot
  supply it: a stored `chart_blob` is opaque by ADR-0003 decision 1 and
  nothing here decodes one, so the host that saved the chart is the only
  party that can compile it. Defaults to `nil`, "this driver answers no
  parents" - a host without one calls `done_invocation/5` itself, from
  `parent_link/2` and the drive's own `run.donedata`.
```

After a drive returns from `advance/6` - in `create/3`, `send_event/4` and
`reenter/5` alike, so a child that completes on a re-entry answers too - the
result is passed through `answer_parent/3`:

`parent_driver` is built exactly as Phase 3 builds a child's:
`%{driver | machine: parent_machine}` - the same store, the same
`serialization:`, the same `effects` executor, the same `dispatch` fun, the
same `chart_resolver:`, a different machine. Only `machine` ever differs, in
both directions, so a grandparent is reached by the same construction
recursing.

- `{:ok, %Run{status: :completed} = run, _}` and the run has linkage and the
  driver has a `chart_resolver` -> resolve the parent's chart from the parent
  run record's `content_hash` and call
  `done_invocation(parent_driver, linkage.parent_run_id, linkage.invoke_id,
  run.donedata)`.
- `{:ok, %Run{status: :failed} = run, _}` -> the same through
  `failed_invocation/5` with `reason: run.failure`.
- Anything else, no linkage, or no resolver -> the drive's own result,
  unchanged.

The parent's answer is a separate drive under the parent's own exclusion, and
its result is deliberately **not** returned: the caller drove the child and
gets the child's result. A parent that has already cancelled the invocation
answers `{:discarded, _}` there, which is ADR-0007 decision 3's mechanism doing
its job and not an error for the child's caller to see.

`answer_parent/3` is **public** - `(driver, child_run_id, donedata_or_failure)`
- so a host with no `chart_resolver:` can call it explicitly with a driver
built over the parent's chart, and so the automatic path and the manual path
are one implementation rather than two. The automatic path is that same
function called with a driver the resolver produced.

#### 3. The linkage read

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `parent_link/2` - `(store, run_id) -> {:ok, %Linkage{}} |
:no_parent | {:error, Storage.error()}` - the "find my parent" query, one key
read off the child's own fetched record.

#### 4. Tests and changelog

**File**: `test/statifier_persistence/driver_subchart_test.exs`,
`changelog.d/sp-nt8.md` (append).

Cases: a child whose chart reaches a top-level `<final>` with `<donedata>`
puts that data on `run.donedata`; with a `chart_resolver`, completing the
child moves the parent out of its invoking state and the parent's `_event`
data is the child's donedata; without a resolver, the parent is untouched and
`parent_link/2` returns the linkage a host would use; a child that fails
answers the parent through the failing door with `reason` set; the whole path
works across a restart - the child is completed by a driver built fresh, which
has never seen either run.

Mutations: return `nil` from `done_effect/1` (the donedata cases); call
`done_invocation/5` with the *child's* run id (the parent-moves case); skip
`answer_parent/3` entirely (the end-to-end case).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `Run.donedata` is `nil` on every existing test's returned run - i.e. no
      existing assertion changes meaning.

#### Manual Verification:
- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] The `chart_resolver:` docstring says plainly why the package cannot
      supply it (ADR-0003 decision 1), so a host does not read it as an
      omission.
- [ ] No parent-child transport exists anywhere: grep confirms the only path
      from child to parent is `done_invocation/5` / `failed_invocation/5`
      (ADR-0008 decision 3, "no bespoke parent-child channel").

**Implementation Note**: as Phase 1.

---

## Phase 5: Cascading cancel

### Overview

ADR-0008 decision 5: when the parent leaves the invoking state, the child is
cancelled, and so are its own children, recursively - nothing deleted,
everything retained under `:cancelled`, and re-running it a no-op.

### Changes Required:

#### 1. The trigger

**File**: `lib/statifier_persistence/driver.ex`
**Changes**: `perform/5` gains a clause for the `{:cancel_invoke,
%CancelInvoke{}}` effect - the core's own reaction to a state exiting while one
of its `<invoke>`s is live
(`deps/statifier/lib/statifier/effect/cancel_invoke.ex`), one effect per
invocation. It is not routed through `dispatch`: cancelling a durable child is
this package's own storage operation, not a call the host performs, and
statifier_blocks ADR-0008 decision 4 says the handler offers no durable
counterpart to `cancel/2`.

```elixir
defp perform(driver, {:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}}, context, _r, _ref) do
  cascade(driver.store, Linkage.invocation_match(context.run_id, invoke_id), opts)
end
```

#### 2. The cascade

**File**: `lib/statifier_persistence/runs.ex`
**Changes**: `cascade_cancel/3` beside `cancel/3`.

```elixir
@doc """
Cancels every run linked to `parent_run_id` - for one invocation, or for
all of them - and every run linked to those, recursively (ADR-0008
decision 5).

Retains: nothing is deleted and every position is left byte-identical;
each run simply takes the `:cancelled` terminal status through `cancel/3`.

Idempotent, and idempotent in the strong sense a crash needs. The walk
descends into every child it finds, whatever that child's own status, and
`cancel/3` discards a run that is already terminal - so a cascade
interrupted halfway through a deep tree is completed correctly by
re-running it, and a cascade over a subtree that is already fully
cancelled writes nothing at all.

There is no global transaction and there deliberately is none: each
run's cancel is its own serialized write under its own run's exclusion
(ADR-0004 decision 5), so a deep tree is O(subtree) writes. Cross-run
locking is the only way to make it atomic, and this package does not have
it and does not want it.

Termination rests on the run tree being acyclic, which it is by
construction: a child's run id strictly extends its parent's
(`StatifierPersistence.Run.Linkage.child_run_id/3`), so no run can be its
own descendant. This is why no depth ceiling is needed (ADR-0008
decision 6).
"""
@spec cascade_cancel(Storage.t(), Adapter.metadata(), keyword()) ::
        {:ok, non_neg_integer()} | {:error, error()}
```

Implementation: `Storage.list_runs_by_metadata/2` with the match map; for each
returned record, `cancel/3` it (a discard is fine and is counted as
already-cancelled), then recurse with `Linkage.parent_match(record.run_id)`.
Returns the count of runs newly moved to `:cancelled`.

Note on ordering: the child is cancelled *before* the walk into its own
children, so an interrupted cascade always leaves the deepest still-active
runs reachable from a run that is already cancelled - which the re-run finds,
because the walk descends through cancelled runs too.

#### 3. Late completions

**File**: none - this is the assertion, not a change.

A completion arriving for a cancelled invocation is dropped by ADR-0007
decision 3's existing mechanism and no new one: `late_answer/3`
(`driver.ex:420-426`) reverse-looks-up the invocation id in the parent's
persisted `active_invocations` inside the serialization strategy, does not
find it (the core emptied it on exit, which is what produced the
`cancel_invoke` effect in the first place), and returns `{:discarded, run}`.

#### 4. Tests and changelog

**File**: `test/statifier_persistence/driver_subchart_test.exs`,
`changelog.d/sp-nt8.md` (append).

Cases: a parent that times out out of the invoking state leaves the child
`:cancelled` and its position byte-identical to what it was before; a
three-deep tree is fully `:cancelled` from one parent timeout; re-running the
cascade over an already-cancelled subtree writes nothing (assert via a count
of `0` and unchanged `updated_at`/record equality); a cascade interrupted
after the first level - simulated by cancelling one level by hand and then
running the cascade - completes the rest; a child of a cancelled parent that
is *itself* already `:completed` is left `:completed`, not overwritten; a
completion for the cancelled invocation is `{:discarded, _}` and the parent's
position is unchanged.

Mutations: skip the recursion (the three-deep case); use `update_run_status/4`
with `:cancelled` unconditionally instead of `cancel/3` (the
already-terminal case); descend only into runs this walk just cancelled (the
interrupted case).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] A cancelled run's `position_blob` is byte-identical before and after,
      asserted directly on the fetched record.
- [x] Nothing in `lib/` deletes a run: grep finds no delete callback and none
      is added.

#### Manual Verification:
- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] Against the Ecto adapter, a cascade inside the parent's `lock_run/3`
      transaction acquires the children's advisory locks parent-first and
      commits - i.e. the nested exclusion works in Postgres, not only against
      the in-memory Agent. Run the Ecto subchart test and confirm no lock
      timeout and no `deadlock detected`.
- [ ] The `cascade_cancel/3` docstring states the retain rule, the
      idempotency rule, and the no-global-transaction consequence, all three.

**Implementation Note**: as Phase 1.

---

## Phase 6: The two named restart races

### Overview

ADR-0008 decision 5 makes two scenarios hard acceptance criteria, extending
ADR-0007's own race file. Both are the claim ADR-0007 made for a single
invocation, made again where the answering party is itself a durable run that
can be mid-step.

### Changes Required:

#### 1. The race file

**File**: `test/statifier_persistence/driver_restart_race_test.exs`
**Changes**: a new `describe "durable subchart"` block, alongside the four
existing cases, which are untouched. The file's `cold_node/1` helper is the
pattern: every "node" is a separately built `Driver` over the same store,
holding no run state, so a fresh one is exactly what a cold node builds.

**Race 1 - cancel versus child completion across a parent restart.**

The parent starts a durable child, the parent takes its `timeout` transition
out of the invoking state (which cascades the cancel), the driver is
discarded, and the child's answer then arrives on a driver built fresh that
has never seen the invocation live.

```
1. cold_node/1 creates "run_parent"; the child exists and is :active.
2. A second cold_node sends "timeout": the parent is in "abandoned" and the
   child is :cancelled, read back through Storage.fetch_run/2.
3. A third cold_node calls done_invocation/5 for "call".
4. Assert {:discarded, run}, run.status == :active, and the parent's
   position - loaded through Storage.load_run_position/3, not taken from a
   return value - is still "abandoned" and never "leaked".
```

**Race 2 - child completes while the parent is mid-restart.**

The point of this one is narrower than "two things happen at once": the
liveness read and the step it gates must fall under **one** exclusion, not
two. The test makes that observable rather than asserting it structurally: a
serialization strategy is supplied whose `with_run/3` blocks the parent's
answering step at a controlled point while a second process delivers the
`timeout` that cancels the invocation, and the answer must still be
`{:discarded, _}` - because the builder's read is taken inside the same
`with_run/3` that the step runs in (`runs.ex:300-321`), so the cancel cannot
land between them.

```
1. cold_node/1 creates "run_parent" with the child live.
2. Build a driver whose `serialization:` is a test strategy that signals the
   test process on entry and waits for a go-ahead before running the tail.
3. Task A: done_invocation/5 for "call" through that driver.
4. On the entry signal, Task B: send_event "timeout" through an ordinary
   driver. It must block on the same run's exclusion - assert it has not
   completed.
5. Release Task A. Assert the completion won (the parent is "approved") and
   that Task B then takes it to "settled" - i.e. the two never interleaved,
   and the outcome is one of the two serial orders and not a mixture.
```

The test strategy lives in `test/support/`, beside whatever this repo already
puts there, not in `lib/`.

#### 2. The moduledoc

**File**: `test/statifier_persistence/driver_restart_race_test.exs`
**Changes**: the moduledoc gains a paragraph naming the two durable-subchart
scenarios and citing ADR-0008 decision 5 as their source, the way the existing
text cites sp-e50 and campaign-024 ruling R-c.

#### 3. Changelog

**File**: `changelog.d/sp-nt8.md` - final pass, so the fragment describes the
whole feature as a user sees it, not the six phases.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] Both new cases are in
      `test/statifier_persistence/driver_restart_race_test.exs`, and the four
      pre-existing cases in that file are unchanged (`git diff` shows
      additions only within the existing cases' line range).
- [x] The suite still runs `async: true` - no new global state.

#### Manual Verification:
- [ ] Both new cases confirmed red under a mutation (a process attestation,
      not a gate-checkable state): for race 1, drop `:cancelled` from the
      cascade so the child stays `:active` *and* remove the `late_answer/3`
      liveness read, so the answer is delivered to the abandoned parent and it
      lands in "leaked"; for race 2, move the liveness read out of the builder
      and into `reenter/5` before the call, so the cancel lands in the window
      and the answer is delivered anyway.
- [ ] Race 2 genuinely blocks rather than passing by timing luck: run it 20
      times (`mix test <file> --seed 0 --repeat-until-failure 20` or an
      equivalent loop) and confirm it is stable.
- [ ] Reading the file top to bottom, a reviewer can tell which case is
      ADR-0007's and which is ADR-0008's, and why the second needs a
      serialization strategy where the first does not.

**Implementation Note**: as Phase 1.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_persistence/run_linkage_test.exs` (new) - the reserved
  namespace, the derivation, the two match maps, the no-linkage arm.
- `test/statifier_persistence/runs_test.exs` - `cancel/3`, the terminal
  guards, the reserved-key refusal, `cascade_cancel/3`'s idempotency and its
  descent through already-cancelled runs.
- `test/statifier_persistence/driver_subchart_test.exs` (new) - the whole
  durable-subchart path against `InMemory`: create, linkage, pin, re-drive
  idempotency, refusals, nesting, completion, cascade.
- `test/statifier_persistence/driver_restart_race_test.exs` - the two named
  races.
- `lib/statifier_persistence/testing/storage_conformance.ex` - the
  `:cancelled` round trip for every adapter, and the containment listing for
  every adapter that exports it. This is what makes the fourth status arm and
  the enumeration a contract rather than an implementation detail, and it runs
  against Postgres through the existing Ecto conformance test.

Key edge cases, each with a named case: a re-driven `start_child` after a
crash (`:run_exists` is success); a `run_exists` collision whose linkage names
a *different* parent (refusal, not adoption); an unidentified child chart (the
pin cannot be recorded, so refuse); an adapter with no metadata support and
one with no child enumeration (both refuse at open, before any write); a
completion arriving for a run already `:cancelled` (discarded); a cascade
re-run over a fully cancelled subtree (writes nothing).

Every new test asserting `lib/` behavior is sabotaged red first, with the
mutation noted in one line above the test - the mutations are named per phase
above so the implementer does not have to invent them.

### Manual Testing Steps:

1. Run the full gate: `mix quality`. Read the `○` lines; a skipped stage is
   not a passing one.
2. Run the Ecto-backed tests against a live Postgres and confirm the cascade's
   nested `lock_run/3` transactions commit with no deadlock.
3. Repeat the race-2 case 20 times and confirm stability.
4. Grep `lib/` for `"statifier_persistence"` as a metadata key and confirm
   `Run.Linkage` is the only reader.
5. Read the changelog fragment as a user of the library and confirm it says
   what changed for them.

## References

- Source document: `docs/adr/0008-durable-subchart-child-runs.md` (accepted,
  binding, not editable by this bead)
- Related ADRs: `docs/adr/0003-storage-adapter-behaviour-and-the-identity-guard.md`,
  `docs/adr/0004-run-lifecycle-executor-seam-and-serialization.md`,
  `docs/adr/0006-optional-opaque-run-metadata.md`,
  `docs/adr/0007-async-invocation-seam.md`
- Sibling record: statifier_blocks `docs/adr/0008-durable-subchart-handler.md`
  (handler shape and the four-reason refusal set; the durable-only reason is
  spelled `child_run_creation_failed`)
- Similar implementation: `lib/statifier_persistence/runs.ex:249` (`fail/4`,
  the template for `cancel/3`), `lib/statifier_persistence/driver.ex:405`
  (`reenter/5`, the template for a door), `storage/ecto.ex:312`
  (`list_runs_by_metadata/2`, promoted to a callback in Phase 1)
- Instruction emitters:
  `deps/statifier/lib/statifier/invoke/handler/scxml.ex:33`,
  `statifier_blocks/lib/statifier_blocks/runtime/subchart.ex:190`
- Bead: sp-nt8 (mirrors sb-2i04; the pair closes together on the operator's
  word)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Every new test was confirmed red under its noted mutation before the
      revert. This is a process attestation, not a gate-checkable state - no
      command re-applies a mutation after the fact - so it belongs here and is
      the implementer's to affirm per the repo's sabotage convention.
- [ ] Reading `Adapter.run_status`'s typedoc, a third-party adapter author can
      tell that `:cancelled` is terminal and that no callback validates the
      transition.
- [ ] No `status in [...]` guard anywhere in `lib/` still lists only two
      terminal arms (grep for `:completed, :failed`).
- [ ] The changelog fragment reads as an effect on a user of the library, not
      as a description of the diff.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] Exactly one module in `lib/` reads a metadata key (grep for
      `reserved_key` and for literal `"statifier_persistence"`), so ADR-0006
      decision 1's narrowing is as narrow as the record says.
- [ ] The moduledoc states the pin is mandatory and says why, in this
      package's own vocabulary rather than by citing the ADR alone.

**Implementation Note**: as Phase 1.

---

### Phase 3

- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] The `Driver` moduledoc no longer says durable subcharts are out of
      scope, and the replacement section says who emits the instruction and
      who executes it.
- [ ] The refusal string is byte-identical to statifier_blocks ADR-0008
      decision 5's `child_run_creation_failed`.
- [ ] A host that never returns the new arm sees no behavior change anywhere.

**Implementation Note**: as Phase 1.

---

### Phase 4

- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] The `chart_resolver:` docstring says plainly why the package cannot
      supply it (ADR-0003 decision 1), so a host does not read it as an
      omission.
- [ ] No parent-child transport exists anywhere: grep confirms the only path
      from child to parent is `done_invocation/5` / `failed_invocation/5`
      (ADR-0008 decision 3, "no bespoke parent-child channel").

**Implementation Note**: as Phase 1.

---

### Phase 5

- [ ] Every new test confirmed red under its noted mutation (a process
      attestation, not a gate-checkable state).
- [ ] Against the Ecto adapter, a cascade inside the parent's `lock_run/3`
      transaction acquires the children's advisory locks parent-first and
      commits - i.e. the nested exclusion works in Postgres, not only against
      the in-memory Agent. Run the Ecto subchart test and confirm no lock
      timeout and no `deadlock detected`.
- [ ] The `cascade_cancel/3` docstring states the retain rule, the
      idempotency rule, and the no-global-transaction consequence, all three.

**Implementation Note**: as Phase 1.

---

### Phase 6

- [ ] Both new cases confirmed red under a mutation (a process attestation,
      not a gate-checkable state): for race 1, drop `:cancelled` from the
      cascade so the child stays `:active` *and* remove the `late_answer/3`
      liveness read, so the answer is delivered to the abandoned parent and it
      lands in "leaked"; for race 2, move the liveness read out of the builder
      and into `reenter/5` before the call, so the cancel lands in the window
      and the answer is delivered anyway.
- [ ] Race 2 genuinely blocks rather than passing by timing luck: run it 20
      times (`mix test <file> --seed 0 --repeat-until-failure 20` or an
      equivalent loop) and confirm it is stable.
- [ ] Reading the file top to bottom, a reviewer can tell which case is
      ADR-0007's and which is ADR-0008's, and why the second needs a
      serialization strategy where the first does not.

**Implementation Note**: as Phase 1.

---
