# ADR-0017: Migrating the executions on a chart: one plan per pair of chart hashes applied to every `:active` and `:needs_migration` execution on `from`, a dry run with three per-execution answers, refuse by default and park on request, linked executions through the tree migration, classes as a composition, one verb with its report and span, and rollback as a reverse plan

Status: proposed (2026-09-26)

## Context

ADR-0013 moves one execution onto a newer chart, whole or not at all
(`docs/adr/0013-the-migration-plan.md`). ADR-0014 gives a refused
migration a quarantine to wait in, the status `:needs_migration`
(`docs/adr/0014-the-needs-migration-status.md`). ADR-0015 moves a parent
and its durable children together, and its 2026-09-24 Amendment makes
`migrate/4` refuse an execution that carries a linkage
(`docs/adr/0015-the-tree-migration.md`). Each of the three moves what a
host names by id. None of them moves what a host actually has after it
publishes a revision: every execution still waiting on the old chart.
ADR-0013 decision 9 leaves that sweep to the host - "a host that wants
every execution on a hash moved writes that sweep itself, over the drained
query (`Executions.executions_on/2`, ADR-0012 decision 3) and one
`migrate/4` per execution" - and the drained query answers counts, not
ids. This record decides the sweep as a verb of this package.

A migration is whole or it did not happen, per execution. A batch over
many executions is not one unit: each execution it touches is moved whole
or left as it was, and the answer says which happened to each.

The four nouns keep their one job each. A **document** is the host's
stable name for a thing it authors; a **revision** is one saved edit of it;
a **chart** is the SCXML a revision emits, identified by its content hash;
an **execution** is pinned to one chart hash and re-pinned only by an
explicit migration. In this record "waiting" is the host's case - an
execution resting at a position on its chart - and "park" and "parked"
mean only ADR-0014's quarantine.

### The case this record is written against

A library loan. A loan's execution waits in `awaiting_return` with its
due-date timer pending, for days. While loans wait there, the library
edits the loan's document: `awaiting_return` is renamed, and the check-in
step that routes after it gains a `damaged` outcome. The library publishes
the new revision and must move every waiting loan onto it, or leave each
one safely on the old chart, and it wants to see which it will be before
anything is written.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`acc6c86`**
("Doc links comment and changelog link"), on statifier **2.9.0**, the
version `mix.lock` resolves, and on statifier_blocks **0.35.1** (tag
`v0.35.1`), read 2026-09-26. Every code cite carries an anchor, because
line numbers move and anchors do not.

- **The one-execution move exists and refuses without writing.**
  `StatifierPersistence.Executions.migrate/4` takes the store, the
  execution id, one `%StatifierPersistence.Migration.Plan{}` and options
  (`from_machine:`, `to_machine:`, `on_failure:`, `pin_sources:`,
  `serialization:`), and answers `{:ok, execution, migrated}`,
  `{:parked, {:migration_refused, findings}}` or `{:error, reason}`
  (`lib/statifier_persistence/executions.ex`, `migrate/4`, @acc6c86).
  ADR-0013's 2026-09-23 Note "what `migrate/4` answers, as built"
  lists every arm.
- **It refuses a linked execution before any other check.** An execution
  whose metadata reads as a linkage is refused with
  `{:error, {:linked, execution}}` and nothing is written under either
  `on_failure:` value (`executions.ex`, `check_unlinked/1`, @acc6c86;
  ADR-0015's 2026-09-24 Amendment).
- **The tree move takes one plan per node, keyed by execution id.**
  `Executions.migrate_tree/4` takes the store, a root execution id, `plans`
  (a map from execution id to plan) and options (`machines:`, a map from
  content hash to compiled machine, `on_failure:`, `pin_sources:`,
  `serialization:`); a node absent from `plans` is left untouched and must
  still resolve against its parent; a child named in `plans` has its
  linkage pin rewritten in the same unit as its row (`executions.ex`,
  `migrate_tree/4` and `linkage_pin/3`, @acc6c86; ADR-0015 decisions 1
  and 3). An adapter without the unit is refused with
  `{:error, :tree_migration_unsupported}` (`check_tree_unit/1`,
  @acc6c86).
- **The drained query counts; no listing names the parked executions on a
  hash.** `Executions.executions_on/2` answers a count per stored arm
  (`executions.ex`, `executions_on/2`, @acc6c86).
  `Storage.list_active_execution_ids_by_content_hash/2` lists ids of the
  `:active` arm only (`lib/statifier_persistence/storage.ex`,
  `list_active_execution_ids_by_content_hash/2`, @acc6c86), and its
  callback's doc says a `:needs_migration` execution is not listed
  (`lib/statifier_persistence/storage/adapter.ex`,
  `c:list_active_execution_ids_by_content_hash/2`, @acc6c86). ADR-0014
  decision 4 keeps that listing `:active` only on purpose: "the listing's
  meaning - fixed in a released version - is not widened".
- **Both queries sit behind one capability.** An adapter that does not
  declare `c:supports_content_hash_query?/1` is answered
  `{:error, :content_hash_query_unsupported}` by the facade without being
  called (`storage.ex`, `count_executions_by_content_hash/2` and
  `list_active_execution_ids_by_content_hash/2`, @acc6c86).
- **Refusing an unsupported shape of a request, whole, has a precedent.**
  An adapter that cannot confine a prune batch to a scope answers
  `{:error, :unscoped_adapter}` and clears nothing (ADR-0016's
  2026-09-25 Amendment, decision 4; `c:prune_executions/4`'s doc in
  `storage/adapter.ex`, @acc6c86).
- **Every event of this package's execution family is under the singular
  `:execution` segment**, the step span included:
  `[:statifier_persistence, :execution, :step, :start | :stop |
  :exception]` and `[:statifier_persistence, :execution, :migrated]`
  (`docs/telemetry.md`, the event tables, @acc6c86).
- **The engine classes a pair of charts and answers a per-position
  predicate; neither moves anything.** `Statifier.Chart.diff/3` takes two
  machines and an optional `mapping:` from a `from` state id to a `to`
  state id and answers `%{class: class, reasons: reasons}`, `class` one of
  `:identical`, `:compatible`, `:mapped` or `:breaking`; a mapping entry
  whose key is not a `from` state absent from `to` is reported as
  `:mapping_unused` (statifier 2.9.0, `Statifier.Chart`, `diff/3`).
  `Statifier.Position.compatible_at?/3` takes the from machine, the to
  machine and an export, and answers whether the execution's own surface
  at that position is unchanged; it takes no mapping (statifier 2.9.0,
  `Statifier.Position`, `compatible_at?/3`). Nothing in this package's
  `lib/` calls either at `acc6c86`.
- **statifier_blocks maps two revisions of one document in either
  order.** `StatifierBlocks.Migration.plan/2` answers `"states"`,
  `"history"` and `"invocations"` in ADR-0013's field names, plus an
  `"unmapped"` report, and refuses two artifacts of different documents;
  "two artifacts of one document map in either order" (statifier_blocks
  0.35.1, `StatifierBlocks.Migration`, `plan/2`, clauses M4 and M5).

### What the library-loan spike found, 2026-09-26

The library-loan spike, 2026-09-26, drove the case above through
statifier 2.9.0, statifier_blocks 0.35.1, statifier_persistence 0.19.0,
statifier_oban 0.13.0 and statifier_router 0.6.0, in a host example
application. Its findings, cited below where they bear on a decision:

- **S1.** A label-only rename keeps the block-derived state id and classes
  `:compatible`, and `compatible_at?/3` answers `true` at the waiting
  state. Any block-id change classes `:breaking` even with a hand mapping,
  because block ids are in event names; the blocks plan never emits a
  rename, so `:mapped` is not reachable from a blocks document, and its
  identity entries surface as `:mapping_unused`.
- **S2.** `migrate/4` on the label-only pair works; the pending due-date
  timer is kept and fires to completion on the to chart.
- **S3.** The loan case has no child executions, so it does not exercise
  `migrate_tree/4`.
- **S4.** A host adapter may refuse the by-hash listing: the example
  application's SQLite adapter answers
  `{:error, :content_hash_query_unsupported}` to
  `list_active_execution_ids_by_content_hash/2`.
- **S5.** `migrate/4` does not check that a kept timer's event is still
  handled by the to chart.

## Decision

The substance of decisions 1 to 7 was ruled by the operator, 2026-09-26,
and is stated here as ruled. The names decision 6 gives - the verb, its
options, the report's fields and the span's event names - and decisions 8
and 9, which that scope forces, are this record's.

**1. One plan per (from, to) pair, applied to every execution on
`from`.** The batch takes one ADR-0013 plan and applies it to every
`:active` and every `:needs_migration` execution stored on the plan's
`from` hash. There are no per-execution overrides: an execution the one
plan cannot move is refused (decision 3), never given a plan of its own by
the batch. The host builds the plan from statifier_blocks' mapping
(`StatifierBlocks.Migration.plan/2`), copying its `"states"`, `"history"`
and `"invocations"` into the plan's map form, as ADR-0013 decision 8
already provides; the batch takes a `%Plan{}` and never builds one.

**2. The dry run, and its three per-execution answers.** With
`dry_run: true` the batch runs the plan's static check once, then, for
each execution, every check `migrate/4` makes - the linkage, the terminal
status, the from hash, the pin sources, the export, the transform and the
import - under that execution's serialization, and writes nothing. Each
execution answers one of three:

- `{:would_migrate, %{dropped: dropped, compatible_at: boolean}}` - the
  plan would move it; `dropped` is what `migrate/4` would report, and
  `compatible_at` is `Statifier.Position.compatible_at?/3` over the from
  machine, the to machine and the execution's export at its position. The
  dry run is the predicate's first caller in this package. It is advice for
  the host and gates nothing: an execution answers `:would_migrate` with
  `compatible_at: false` when the plan applies and the surface at its
  position changed (a renamed active state is one, because the predicate
  takes no mapping).
- `{:would_refuse, reason}` - `migrate/4` would refuse it; `reason` is
  `migrate/4`'s own refusal, `{:migration_refused, findings}` carrying the
  findings of the validation against the execution.
- `{:skipped, :terminal | :linked}` - the execution is terminal, so there
  is nothing to move, or it carries a linkage, so it moves through the
  tree migration at apply (decision 4) and the per-execution checks do not
  preview it.

Under the dry run `on_failure:` changes nothing, because nothing is
written. The apply re-checks everything. The dry run is advice, never a
lock: it
holds no exclusion past each execution's own check, and an execution that
changes between the dry run and the apply is answered by the apply as it
then stands.

**3. `on_failure: :refuse` by default, `:park` only on request.** Under
`:refuse`, the default, a refused execution is written nothing: an
`:active` one stays `:active` on the old chart and keeps draining there,
and a `:needs_migration` one stays parked. Under `:park`, which the host
asks for, a refusal that ADR-0013 decision 4 parks for one execution, or
ADR-0015 decision 4 parks for a tree, parks it, and every parked execution
id is in the report. A refusal that parks nothing there parks nothing in
the batch.

**4. Linked executions through `migrate_tree/4`.** An execution that
carries no linkage moves through `migrate/4`. An execution on `from` that
carries a linkage - a durable child - moves through `migrate_tree/4`
rooted at it, with a `plans` map the batch builds from the one plan: the
execution's own id mapped to the plan, and `machines:` holding the plan's
`from` and `to` machines. A node of its subtree on another hash is absent
from `plans` and stays where it is, under ADR-0015 decision 1's resolve
rule. A node of its subtree on `from` is an execution on `from` in its
own right and is moved on its own turn, rooted at itself. The
linked-execution refusal of `migrate/4` is unchanged: the batch does not
call `migrate/4` to move a linked execution, and the refusal still stands
for every host that does.

**5. Classes are a composition; no new class and no new function for
them.** A host that wants a pair's class computes it from what exists:
`StatifierBlocks.Migration.plan/2`, then `Statifier.Chart.diff/3` with
`mapping:` the plan's `states`, then the class. The dry run asks
`compatible_at?/3` per execution (decision 2). The batch takes no class,
computes none and refuses nothing on a class; the host decides whether a
pair is worth migrating. By S1, a label-only edit in a blocks document
classes `:compatible` and answers `compatible_at: true` at the waiting
state, and an edit that changes a block id classes `:breaking`, so a host
reading the class of a blocks pair sees `:identical`, `:compatible` or
`:breaking`, and `:mapped` only for a hand-written chart. Automatic migration on publish
stays out of this record.

**6. The verb, its report and the batch span.** The family's surface is
one verb and its report: the dry run is the preview, the apply is the
batch, and the report carries a result per execution. The verb is
`StatifierPersistence.Executions.migrate_batch/3`, and its options are:

- `from_machine:` and `to_machine:` - required, the two compiled machines,
  with `migrate/4`'s meaning.
- `dry_run:` - `true` or `false`, default `false` (decision 2).
- `on_failure:` - `:refuse` or `:park`, default `:refuse` (decision 3).
- `pin_sources:` - a list of pin source modules, default `[]`, with
  `migrate/4`'s meaning, handed to every execution's check.
- `serialization:` - the strategy every `Executions` entry point takes,
  defaulting as they do, applied per execution.

It answers `{:ok, report}` or `{:error, reason}`. The report is a map of
`from` and `to` (the plan's hashes), `dry_run`, `results` - a list of
`{execution_id, outcome}` in the order the batch took them, ascending
execution id - and `counts`, a map from each outcome of the mode to the
number of executions that answered it, every key present, zeros included.
Under the dry run the outcomes are decision 2's three. Under the apply
they are:

- `{:migrated, migrated}` - moved; `migrated` is the facts `migrate/4`
  answers for one execution (for a linked execution, the facts
  `migrate_tree/4` answers for its root).
- `{:refused, reason}` - refused and written nothing; `reason` is
  `migrate/4`'s refusal, or `migrate_tree/4`'s for a linked execution.
- `{:parked, reason}` - parked under `on_failure: :park`, with the refusal
  that parked it.
- `{:skipped, :terminal}` - terminal when its turn came.

So the report names every migrated, refused, parked and skipped id.
`{:error, reason}` is a refusal of the whole batch before any execution is
read, and writes nothing under either mode: a static fault of the plan,
a tombstoned `to` hash, a missing pin source (each `migrate/4`'s own arm,
decided once for the batch), and the listing's refusal (decision 8). A
malformed option raises before anything is read, as `migrate/4`'s do.

One telemetry span covers the batch:
`[:statifier_persistence, :execution, :migrate_batch, :start]`,
`[..., :stop]` and `[..., :exception]`. Its `:start` carries
`system_time` and `monotonic_time`; its `:stop` carries `duration`,
`monotonic_time` and one measurement per outcome of the mode, the report's
`counts`; its `:exception` carries `duration` and `monotonic_time`. Every
one carries `from`, `to`, `dry_run` and `span_ref` as metadata; the
`:stop` adds `outcome` (`:ok` or `:error`) and `reason` (`nil`, or the
batch's refusal), and the `:exception` adds `kind`, `reason` and
`stacktrace` as the step span's does. The per-execution
`[:statifier_persistence, :execution, :migrated]` event is unchanged: each
execution moved inside the span emits it once, as `migrate/4` and
`migrate_tree/4` emit it today, and a dry run emits none.

**7. Rollback is a reverse plan.** A host that wants a batch undone builds
the reverse plan, `to` -> `from` (statifier_blocks maps one document's two
revisions in either order), and hands it to the same verb. That works
while `from` is not retired; once ADR-0012 has tombstoned `from`, the
reverse plan's `to`, the verb refuses the whole batch with ADR-0012's
retired arm before anything is read. No rollback state is stored, and
nothing records which executions a batch moved beyond its report.

**8. How the batch finds the executions on `from`: one additive listing,
behind the existing capability.** The batch needs the ids of the `:active`
and the `:needs_migration` executions on one hash, and the only listing
that exists names `:active` only and is fixed that way (Context). So the
storage layer gains one function and one optional adapter callback,
shipped in the 0.20.0 minor with the verb:

- `StatifierPersistence.Storage.list_execution_ids_by_content_hash/3` -
  the store, the content hash, and a non-empty list of stored statuses;
  answers `{:ok, ids}`, ascending execution id, for the executions on that
  hash in any of those statuses, and `{:ok, []}` for a hash the store has
  never seen.
- `c:StatifierPersistence.Storage.Adapter.list_execution_ids_by_content_hash/3`,
  taking the adapter's options, the hash and the statuses; part of
  `c:supports_content_hash_query?/1`'s capability, as
  `c:list_active_execution_ids_by_content_hash/2` is, and implemented by
  both shipped adapters.

The batch asks it for `[:active, :needs_migration]`, once, before any
execution is read, outside every exclusion, and takes the listing as its
work: an execution that lands on `from` after the listing is not in this
batch. The existing `:active`-only listing and its callback are
unchanged, so every pin source and every retirement reads what it read
before. A status-set argument, rather than a second fixed listing, is
chosen because the batch is the second caller that needs a different arm
set from the same column, and a fixed listing per arm set would add a
callback for each.

**9. What the batch answers for an adapter that cannot list by hash:
the listing's own refusal, whole.** An adapter that does not declare
`c:supports_content_hash_query?/1` is refused by the facade with
`{:error, :content_hash_query_unsupported}` without being called, as the
drained query and the `:active` listing are. An adapter that declares the
capability but does not export the new callback - one written against
0.19 - gets the same answer from the facade, which checks the export too,
rather than an undefined-function error. An adapter that answers the
listing with an error, as the spike's SQLite adapter answers the `:active`
listing (S4), has that error passed through. In every case the batch answers
`{:error, reason}` before any execution is read and writes nothing, as a
prune refuses a scope it cannot confine rather than clearing more or
less than asked. No error arm is added. The batch never falls back to the
`:active`-only listing: that would leave every parked execution on `from`
out of a batch ruled to cover them, without saying so.

## Consequences

**This record's text binds the implementing code.** The code change builds
`migrate_batch/3`, the listing of decision 8 on both shipped adapters and
in the storage conformance cases, and each cites the decision it
implements. Its cases, on the library-loan pair over both shipped
adapters: a dry run writes nothing, read back; a dry run and then an
apply agree when nothing changed between them; a refused execution stays
`:active` on `from`; `:park` parks and lists; a linked execution moves
with its linkage pin; a terminal execution is skipped; a reverse plan
returns an execution to `from`. The loan case has no children (S3), so the
linked case uses a fixture of its own.

**`migrate/4`, `migrate_tree/4` and `unpark/3` do not change.** The verb
is additive and each existing caller sees what it saw. `migrate/4` keeps
the linked-execution refusal.

**ADR-0013 decision 9's sweep sentence has a package answer.** "A host that
wants every execution on a hash moved writes that sweep itself" and
"Nothing in this package calls `migrate/4`" both describe the package
before this verb: the verb is that sweep, and it calls `migrate/4` and
`migrate_tree/4`, never on a save, a create or a step. ADR-0013 is not
edited by this record; this record is the dated record that names the
change.

**Closed sets grow in the 0.20.0 minor.** The span adds three event names
to ADR-0009 decision 8's frozen list, and `docs/telemetry.md` gains their
rows with the code that emits them; a dated Note on ADR-0009 points here,
where the span is decided. The adapter behaviour gains one optional
callback. The report is a new shape. None of it ships in a patch.

**A batch is not one unit.** Each execution is moved whole or not at all,
under its own exclusion, as `migrate/4` and `migrate_tree/4` move one; the
batch holds no exclusion across executions and no transaction across
them. An interrupted apply leaves the executions it reached moved,
refused or parked, and the rest untouched on `from`; calling it again
with the same plan lists what is still on `from` and carries on.

**A reverse plan moves everything on `to`.** The batch cannot tell an
execution it moved from one created on `to` after it, so a rollback moves
both. A host that wants only the moved ones back reads the forward
report's `results` and moves them one by one.

**Timers.** A plan that maps every state that could own a timer needs no
pin source, as ADR-0013 decision 6 says; the loan's due-date timer is kept
and fires on the to chart (S2). The spike found one gap this record names
and does not decide: `migrate/4` does not check that a kept timer's event
is still handled by the to chart (S5), so neither does the batch.

### What this record does not decide

- Migration at publish time, in any form, including automatic migration
  of a `:compatible` pair. Nothing migrates an execution because a chart
  was saved, created against or published.
- Paging the listing or the batch; the listing is taken whole.
- A dry run of a linked execution's tree; decision 2 answers it
  `{:skipped, :linked}`.
- The kept-timer gap of S5.
- An editor migrate action, and a view of executions by revision; both are
  the host's admin.
- Where a host stores its plans or its reports.
- Datamodel operations beyond ADR-0013's `add`, `rename` and `remove`.
