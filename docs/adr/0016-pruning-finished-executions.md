# ADR-0016: Pruning a finished execution: `Retention.prune/3` clears the position blob and the input log of every terminal execution that ended before a host's cutoff, keeps the row, leaves the positions table alone, and takes no duration

Status: accepted (2026-09-24, sp-yy7d)

## Context

ADR-0012 retires charts and leaves an execution's own rows alone, and it
says so: "Purging a finished execution's position and input log is a
separate design bead and is not in scope: this record retires charts, and
an execution's own rows are untouched by every decision above"
(`docs/adr/0012-retention-and-retirement.md`, decision 8). This record is
that design.

What a finished execution leaves behind is not small and not neutral. Its
row keeps the last position blob it was written with, and on an adapter
that keeps ADR-0010's input log, every input it ever took, verbatim - the
host's own event data at rest for the life of the store. A host with a
data-retention duty has had no supported way to clear either, and the
tables give it no help doing so by hand: nothing in the schema stops a
wrong delete.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`341330a`**,
read 2026-09-24. Code cites carry that SHA and an anchor, because line
numbers move and anchors do not. The functions this record adds are cited
by name alone; they arrive in the same change as the record.

- **No foreign key anywhere.** The inputs table has none, "for the same
  reason no other table here has one: `execution_id` is a caller-supplied
  opaque string this layer stores verbatim ... and a host's own retention
  of executions is not this package's to constrain"
  (`lib/statifier_persistence/ecto/migrations/v05.ex`, moduledoc,
  @341330a). A wrong delete is not refused by the database.
- **An execution row records when it ended, and the stamp is not the
  status.** `ended_at` is written by the first terminal write the row takes
  while it has none, and kept over every later write, including one that
  puts the row back to a status that is not terminal
  (`lib/statifier_persistence/executions.ex`, `ended?/1`, @341330a). V08
  indexes it (`lib/statifier_persistence/ecto/migrations/v08.ex`, `up/1`,
  @341330a).
- **The position blob of an execution row is already nullable.**
  `add(:position_blob, :binary, null: true)` on the executions table
  (`lib/statifier_persistence/ecto/migrations/v01.ex`, `up/1`, @341330a),
  and a load of an execution whose blob is `nil` answers
  `{:error, :execution_position_missing}`
  (`lib/statifier_persistence/storage.ex`, `load_execution_position/3`,
  @341330a).
- **Nothing in this package reads a terminal execution's position.** A
  step on a terminal execution is discarded before the position is loaded
  (`lib/statifier_persistence/executions.ex`, `step_tail/7`, @341330a);
  `fail/4` and `cancel/3` discard it the same way (same file, `fail/4`,
  `cancel/3`, @341330a); and a migration refuses it before any load (same
  file, `check_record/2`, @341330a).
- **Nothing in this package reads the input log.** `Executions.inputs/2`
  is "a diagnostic read, and nothing in this package consumes it"
  (`lib/statifier_persistence/executions.ex`, `inputs/2`, @341330a).
- **A parent reads a finished child's row, never its position or log.** A
  fan-out's settlement assembles each child's entry from the child's
  status and its `outcome_blob` (`lib/statifier_persistence/driver.ex`,
  `entry/5`, @341330a), and a re-driven child create finds the existing
  child by its deterministic id and adopts it
  (`lib/statifier_persistence/driver.ex`, `adopt_child/3`, @341330a).
- **The positions table is keyed by session, not by execution.** It
  carries no end stamp, and the executions table's `session_id` is
  nullable and not written by this package
  (`lib/statifier_persistence/ecto/migrations/v01.ex`, `up/1`, @341330a).
  A position row is one of the four things that pin a chart (ADR-0012
  decision 1).
- **This package has no clock.** "No call takes a duration" (ADR-0012
  decision 7).

## Decision

**1. `StatifierPersistence.Retention.prune/3` clears what a finished
execution leaves behind, and nothing else.** It takes the store, a cutoff
and options, and for every execution it selects it nulls the row's
`position_blob` and deletes every input log row the execution has, the
closed marker included. It answers the counts it cleared - executions,
position blobs, input rows - summed over its batches.

**2. An execution is selected when its status is terminal and its stamp is
strictly before the cutoff.** Both, because neither is enough alone. A row
with no stamp is never selected, whatever its status: it either has not
ended, or ended before V08 and its end time is not stored anywhere. A row
with a stamp is selected only while its status is `:completed`, `:failed`
or `:cancelled`, because the stamp stays on a row a later write put back to
a status that is not terminal, and that execution can still take a step,
which needs the position this prune would clear. The comparison is strict,
so an execution that ended exactly at the cutoff is kept.

**3. The execution row is the tombstone, and it is kept whole.** Its
status, `failure`, `metadata`, `outcome_blob`, content hash, identity
envelope and `ended_at` are untouched, and it is what a pruned execution
leaves: its final status, its answer, and when it ended. This record adds
no column, so the row does not record that it was pruned, nor who asked,
nor when. A host that needs that trail keeps it where it keeps its own
audit.

**4. A pruned execution still counts.** The drained query counts it in its
terminal arm exactly as before, because the counts are history (ADR-0012
decision 3), and a pruned execution pins no chart, as no terminal one does
(ADR-0012 decision 1). Keeping the row also keeps the execution id taken.

**5. The positions table is not touched.** A position row belongs to a
session, carries no end stamp, and is joined to no execution this package
writes, so this package has no way to know that a session is finished.
Deleting one is the host's call, made on its own knowledge of the session;
`docs/retention.md` says what that costs and what it releases (the chart
pin of ADR-0012 decision 1).

**6. The cutoff is a `DateTime` the host supplies, and there is no
default.** `prune/3` raises on anything else - a number of days, a
`Duration`, a `Date` - so ADR-0012 decision 7 holds word for word: no call
takes a duration, no window has a default, and nothing prunes on its own or
on a schedule. When an execution's leftovers should go is the host's
policy.

**7. It is batched and idempotent.** Each batch is at most `batch_size:`
executions, oldest end first, cleared as one atomic unit in the adapter,
and committed on its own. A batch selects only executions that still hold
something to clear, so a second call with the same cutoff answers zeros,
and a call that fails part-way leaves the earlier batches pruned and is
simply made again.

**8. The adapter gains one optional callback and one predicate.**
`supports_execution_pruning?/1` and `prune_executions/3` join
`@optional_callbacks`, in the opt-in-by-export shape the other optional
capabilities use. The facade is `Storage.prune_executions/3`, one batch,
which answers `{:error, :execution_pruning_unsupported}` for an adapter
that does not declare the capability, without calling it. Both shipped
adapters declare it. The in-memory adapter keeps no input log, so its
batches clear position blobs only. The Ecto adapter selects on V08's
`ended_at` index, and on Postgres locks the batch's rows with
`FOR UPDATE SKIP LOCKED`, so a row another transaction is writing is left
for the next call and two prunes at once take disjoint batches.

**9. A log or trace reader after a prune gets no distinct answer yet.**
`Executions.inputs/2` answers `{:ok, []}`, and a load of the execution's
position answers `{:error, :execution_position_missing}`. Neither is a
distinct pruned answer: an empty log is also what an execution that took
no input answers, and the missing position is also what an execution that
failed at creation answers. A distinct answer - so that a replay reader
can refuse a pruned execution rather than read an empty log as a complete
one - needs the row to record that it was pruned, which decision 3 does
not add. It is left for a later record. Until then a host that prunes
knows which executions it pruned by their stamps and its own cutoff. No
trace is stored by this package - its telemetry is emitted, not kept
(ADR-0009) - so there is no trace to prune.

**10. Encrypted blobs: the bytes go, the key stays.** Pruning removes the
ciphertext from the live rows. It touches no key, and no copy of the rows
the host keeps elsewhere, such as a backup. Dropping a key instead of the
bytes is the host's key provider's business, and it makes every blob under
that key unreadable, not only this execution's.

**11. A parent and its durable children are each pruned on their own
stamp, and pruning never cascades.** Decision 3 is what makes either order
safe (ADR-0008's linkage lives in the kept `metadata`). A parent that has
not settled yet reads a pruned child's status and answer from the kept row
exactly as before, and a re-driven child create still finds the child by
its id and adopts it rather than starting a second one. A pruned parent
with a child still running is terminal, so the child's later answer is
discarded before any position is loaded, as it always was.

## Consequences

**Every adapter written before this record stays conformant without a line
of change.** It exports neither new function, the facade finds neither,
and the prune refuses at open. The conformance suite generates its prune
cases only for an adapter that exports `prune_executions/3`, and the input
log case only for one that also exports `append_input/3`.

**`docs/retention.md` is the host's page.** It names which rows a host may
delete for a finished execution and which it must not, with the reason for
each, because the schema declares no foreign key and will not stop a wrong
delete.

**A pruned execution cannot be told from an unpruned one by a read.**
Decision 8 names the cost; the record that adds a pruned marker will also
have to decide what `inputs/2` answers for one, and that is an additional
arm a host matching exhaustively would see.

**The telemetry callback vocabulary grows by two names,**
`:supports_execution_pruning?` and `:prune_executions`, reported by the
facade like every other adapter call. No new event.

**No migration.** The columns this needs are V01's nullable
`position_blob`, V05's inputs table and V08's `ended_at` and its index.

## Note (2026-09-24, sp-nvch): accepted, with the Consequences' "Decision 8 names the cost" read as decision 9

The operator accepted this record on 2026-09-24. The code that implements
it is in statifier_persistence 0.17.0 (tag `v0.17.0`, `174f48c`), which is
tagged but not yet published on Hex: this record is accepted on the
operator's word before the Hex publish. The status line at the top flips in
place from proposed to accepted, and no other line of the record changes.
Every cite below was read on `main` at `174f48c`, the tag. The premise
surface's own files carry no commit after `341330a` other than the change
that added this record.

What was re-read before the flip, decision by decision:

- **The premise surface.** Every premise cite still reads as quoted: the
  inputs table's moduledoc on the missing foreign key
  (`lib/statifier_persistence/ecto/migrations/v05.ex`), the stamp kept over
  a later non-terminal write (`lib/statifier_persistence/executions.ex`,
  `ended?/1`), the nullable `position_blob` and nullable `session_id` on the
  executions table (`lib/statifier_persistence/ecto/migrations/v01.ex`,
  `up/1`), the missing-position answer
  (`lib/statifier_persistence/storage.ex`, `load_execution_position/3`),
  the terminal discards before any load (`step_tail/7`, `fail/4`,
  `cancel/3`) and the migration's refusal (`check_record/2`), the
  diagnostic `inputs/2`, and the parent's read of a child's row
  (`lib/statifier_persistence/driver.ex`, `entry/5`, `adopt_child/3`).
- **Decisions 1, 6 and 7.** `StatifierPersistence.Retention.prune/3` raises
  `ArgumentError` on any cutoff that is not a `DateTime` and on a
  `batch_size:` that is not a positive integer, refuses an adapter without
  the capability before any batch, and sums each batch's counts, stopping
  at the first batch shorter than its limit
  (`lib/statifier_persistence/retention.ex`, `prune/3`).
- **Decisions 2, 3 and 7, per adapter.** The Ecto adapter selects a
  terminal status, `ended_at` strictly before the cutoff and something
  still to clear, oldest end first; deletes the batch's input rows by
  `execution_id`; and sets `position_blob` to `nil` and nothing else, in
  one transaction (`lib/statifier_persistence/storage/ecto.ex`,
  `prune_executions/3`). The in-memory adapter applies the same selection
  in one `Agent.get_and_update/2` and answers `inputs: 0`
  (`lib/statifier_persistence/storage/in_memory.ex`, `prune_executions/3`).
- **Decision 8.** The pair is in `@optional_callbacks`
  (`lib/statifier_persistence/storage/adapter.ex`,
  `supports_execution_pruning?/1`, `prune_executions/3`). The facade answers
  `{:error, :execution_pruning_unsupported}` without calling an adapter
  that does not declare it (`lib/statifier_persistence/storage.ex`,
  `prune_executions/3`). On Postgres the selection takes
  `FOR UPDATE SKIP LOCKED` (`storage/ecto.ex`, `due_executions/3`).
- **Decisions 5, 9, 10 and 11** add no code: no prune path writes the
  positions table, a key, or a second execution, and `docs/retention.md`
  says what the host may and must not delete.
- **Consequences.** The conformance cases are generated only for an
  adapter that exports `prune_executions/3`, and the input log case only
  for one that also exports `append_input/3`
  (`lib/statifier_persistence/testing/storage_conformance.ex`). The two
  callback names are in `docs/telemetry.md`'s closed vocabulary, reported
  through the facade's adapter call. The release adds no schema version.

**"Decision 8 names the cost" in the Consequences is read as decision 9.**
The cost it means - a pruned execution cannot be told from an unpruned one
by a read - is decision 9's; decision 8 is the adapter callback. The
sentence stays as written, and this Note is how it is read.

## Amendment (2026-09-25, sp-u4mc): `prune/3` takes `scope:`, and the adapter callback becomes `prune_executions/4`

Status of this amendment: accepted (2026-09-25, sp-u4mc). The record above
stays accepted; this amendment is proposed until the operator accepts it.

Decision 1 prunes across the whole store. A host whose tables are
partitioned by a column of its own - one it placed with `:leading_columns`
on `use StatifierPersistence.Ecto` - runs its work one partition at a time,
inside that partition's transaction, and a prune that reads or writes rows
of every partition does not fit there. The operator ruled on 2026-09-25
that `prune/3` gains `scope:`. This amendment records that ruling and
amends decisions 1 and 8.

What it rests on, read on `main` at `453f630`:

- **The package never reads or writes a leading column.** `:leading_columns`
  "only places the column ... the generated schemas do not declare it, so
  the package never reads or writes it"
  (`lib/statifier_persistence/ecto/config.ex`, moduledoc, @453f630).
- **The prune queries are bound to the generated schemas.** The selection
  and both writes are built over `execution_schema(opts)` and
  `input_schema(opts)` (`lib/statifier_persistence/storage/ecto.ex`,
  `due_executions/3` and `prune_batch/3`, @453f630), and Ecto refuses a
  `where` on a field a schema does not declare.
- **`execution_id` is unique on the executions table.**
  `unique_index(executions, [:execution_id], ...)`
  (`lib/statifier_persistence/ecto/migrations/v01.ex`, `up/1`, @453f630).

**1. `prune/3` takes `scope:`, a keyword list of column equalities.** Given,
it is threaded to every batch, and the batch clears only executions whose
row holds every equality. Left out, the prune is decision 1's, unchanged.
`prune/3` raises `ArgumentError` on a scope that is empty, that is not a
keyword list, that names a column twice, or that holds a `nil` value: an
empty scope computed by a host would prune every partition from inside
one, and an equality with `NULL` matches no row. Its code is `scope!/1` in
`lib/statifier_persistence/retention.ex`, landed with this amendment.

**2. The scope reaches every statement of a batch.** The selection, the
input log check inside it, the input log delete and the position blob
update each carry the equalities, so a batch run inside one partition's
transaction reads and writes no row of another. The update is keyed on ids
the scoped selection chose, so on a table where `execution_id` is unique
its equalities change no count; they are there so no statement of the
batch reaches outside the partition.

**3. The adapter callback becomes `prune_executions/4`.** The scope is its
fourth argument, `[]` when the host gave none, typed
`t:StatifierPersistence.Storage.Adapter.prune_scope/0`. It replaces
`prune_executions/3` in `@optional_callbacks`, and
`execution_pruning_supported?/1` checks for the new arity. The facade is
`Storage.prune_executions/4`, its scope defaulting to `[]`. Decision 8's
`prune_executions/3` and `Storage.prune_executions/3` are read as these.

**4. An adapter that cannot scope says so.** It answers
`{:error, :unscoped_adapter}` for any scope that is not `[]` and clears
nothing; `:unscoped_adapter` is a new arm of
`t:StatifierPersistence.Storage.Adapter.error/0`. The in-memory adapter is
one: its records hold no column of the host's.

**5. The Ecto adapter scopes by the host's leading columns and no other.**
A scoped batch queries the executions and inputs tables by name, under the
generated schemas' prefix, because the scope's columns are not schema
fields; an unscoped batch reads through the schemas as before. A column
that is not one of the host's `:leading_columns` raises `ArgumentError`
before any statement runs. A scoped prune is the one place the package
reads a leading column, and the `:leading_columns` documentation quoted
above now says so; it still writes none.

**6. The conformance suite proves both halves.** Its prune cases call the
callback with `[]`, the unscoped answer the scope must not change. A new
`prune_scope:` option on `StatifierPersistence.Testing.StorageConformance`
names a scope inside, a scope outside and a function that places an
execution's rows in a scope, and generates one more case: of two finished
executions, the scoped batch clears the one inside and leaves the one
outside whole, position and input log. The option exists because the
suite cannot place a row in a scope itself: the package never writes a
host's column.

**It is breaking for an adapter written outside this package.** One that
exports `prune_executions/3` is no longer counted as declaring pruning,
and `prune/3` refuses it with `{:error, :execution_pruning_unsupported}`
until it takes the fourth argument. A host matching
`t:StatifierPersistence.Storage.Adapter.error/0` exhaustively needs a
clause for `:unscoped_adapter`. It ships in a minor with a Breaking
changelog line, and it adds no schema version.

The Consequences' sentence "The conformance suite generates its prune
cases only for an adapter that exports `prune_executions/3`" is read with
`prune_executions/4`. The record's other lines stay as written.

## Note (2026-09-25): the sp-u4mc Amendment is accepted

The operator accepted the 2026-09-25 sp-u4mc Amendment on 2026-09-25. The
code that implements it landed in PR 181 (`b02adbb`) and shipped in
statifier_persistence 0.19.0 (tag `v0.19.0`, `6dd9172`) under a Breaking
changelog line. That Amendment's own status line flips in place from
proposed to accepted, and the record above stays accepted. Its "this
amendment is proposed until the operator accepts it" is met here and stays
as written. Every cite below was read on `main` at `adca4f0`.

What was re-read before the flip:

- **Decision 1.** `scope!/1` in `lib/statifier_persistence/retention.ex`
  checks the scope before any batch runs.
- **Decisions 3 and 4.** `c:StatifierPersistence.Storage.Adapter.prune_executions/4`
  takes `t:StatifierPersistence.Storage.Adapter.prune_scope/0` as its
  fourth argument, `:unscoped_adapter` is an arm of the adapter's `error/0`,
  the facade is `Storage.prune_executions/4` with the scope defaulting to
  `[]`, and the in-memory adapter answers `{:error, :unscoped_adapter}` for
  a scope that is not `[]`.
- **Decision 6.** `StatifierPersistence.Testing.StorageConformance`
  documents the `prune_scope:` option.
- **The changelog.** The 0.19.0 section of `CHANGELOG.md` carries the
  Breaking line for an adapter that exports `prune_executions/3`.

One claim of decision 2 has no test of its own: that the position blob
update carries the equalities. sp-x8n6 adds that test or narrows the claim
by a later Note; it does not hold the flip.
