# ADR-0014: The fifth execution status `:needs_migration`: reached only by a parking migration, not terminal, refuses every delivery whole, left by a corrected plan or by `Executions.unpark/3`, counted under its own key and pinning its chart

Status: proposed (2026-09-23, sp-zf8; the code bead sp-3vv builds the arm
against it at proposed and cites its Decision items)

## Context

The migration-plan record (ADR-0013, proposed beside this one) gives
`migrate/4` an `on_failure:` option with two values. Under `:refuse` a
plan that cannot apply to an execution is answered with an error and the
execution is left exactly as it was. Under `:park` the execution is also
left exactly as it was - same position, same chart - but it is marked, so
that nothing steps it forward on a chart its host has already decided to
move it off, and so that a host can find it again. That mark is a status,
and this record decides it.

A migration is whole or it did not happen. Nothing in this record
describes a partial apply, and the park is not one: it is the record that
a migration did *not* happen, written on an execution the migration left
untouched in every other field.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`9cd192b`**
("Promotes the sp-l4p send-types fragment into the 0.13.0 section"), read
2026-09-23. Every code cite carries that SHA and an anchor beside its line
number, because line numbers move and anchors do not.

- **A stored execution's status has four arms.**
  `@type execution_status :: :active | :completed | :failed | :cancelled`
  (`lib/statifier_persistence/storage/adapter.ex:62`, `t:execution_status/0`,
  @9cd192b). ADR-0012 decision 2 names `:completed`, `:failed` and
  `:cancelled` together as "terminal", a fold in prose that is never
  stored.
- **The column needs no schema version.** The status column is
  `add(:status, :text, null: false)`
  (`lib/statifier_persistence/ecto/migrations/v01.ex:69`, the `executions`
  table in `up/1`, @9cd192b), and no migration from V01 to V07 adds a
  constraint, a check or a partial index on it (@9cd192b). The vocabulary
  is enforced in Elixir, by the Ecto adapter's `@statuses` list
  (`lib/statifier_persistence/storage/ecto.ex:64`, `@statuses`, @9cd192b),
  from which `encode_status/1` and `decode_status/1` are generated
  (`ecto.ex:1213`, `for {atom, string} <- @statuses`, @9cd192b). An
  unknown stored string fails loudly on a missing clause, by design.
- **The input log is a replay log, not a queue.** ADR-0010 decision 5
  appends "only inputs the interpreter saw"; decision 6 closes the log
  with a marker past the host's cap; nothing in this package reads the log
  back to deliver it; and `StatifierPersistence.Storage.InMemory` keeps no
  log at all (it exports no `supports_input_log?/1`,
  `lib/statifier_persistence/storage/in_memory.ex`, @9cd192b). So the log
  cannot hold a delivery for later.
- **Every event door reaches one guard.** `step/5`'s fetch-and-guard is
  `step_tail/7` (`lib/statifier_persistence/executions.ex:465`, @9cd192b),
  which discards on `status in [:completed, :failed, :cancelled]` before
  any position is loaded; `StatifierPersistence.Driver`'s `send_event/4`,
  `done_invocation/5`, `failed_invocation/5` and `answer_parent/3` all drive
  through `Executions.step/5` (`lib/statifier_persistence/driver.ex:1499`,
  the one `Executions.step` call in the module, @9cd192b).
- **A status-only write already exists.**
  `StatifierPersistence.Storage.update_execution_status/4`
  (`lib/statifier_persistence/storage.ex:458`, @9cd192b) writes a status and
  carries every other stored field forward verbatim, both blobs included.

## Decision

**1. A fifth arm, `:needs_migration`, reached only by `migrate/4` under
`on_failure: :park`.** `t:execution_status/0` gains `:needs_migration`,
stored by the Ecto adapter as the string `"needs_migration"`. The one way
into the arm is a call to `migrate/4` with `on_failure: :park` whose plan
cannot apply to the execution - either validation in ADR-0013 refuses it.
The park is a status-only write of the kind `update_execution_status/4`
makes: the position, the content hash, the identity blob, the metadata and
the input log are the ones the execution had before the call. Only an
execution in `:active` or already in `:needs_migration` can be parked; a
parked execution that is parked again stays as it is. No step, create,
fail, cancel or retirement writes the arm, and nothing parks an execution
because a chart was published.

**2. It is not terminal, it consumes no events, and a delivery to it is
refused whole.** `:needs_migration` is outside ADR-0012's terminal fold. A
delivery through any event door - `Executions.step/5`, and every
`Driver` door that drives through it - answers
`{:error, {:needs_migration, execution}}`, where `execution` is the
`%StatifierPersistence.Execution{}` built from the stored record. The
refusal is taken from the execution record alone, before any position is
loaded: nothing is appended to the input log, nothing is consumed, no
effect is executed and nothing is written. Holding the delivery and
delivering it again after the execution leaves the arm is the host's; a
retrying job queue does exactly that when a delivery returns an error.

It is a refusal and not a discard on purpose. `{:discarded, execution}`
tells a caller that the event is gone for good and should not be tried
again, which is right for a terminal execution and wrong here: this
execution will take events again, and a host that acknowledges a discarded
delivery has thrown that event away. An error is what a caller retries.

`Executions.fail/4` and `Executions.cancel/3` are host decisions about an
execution rather than events for its chart, and they proceed on a parked
execution exactly as they do on an `:active` one: `fail/4` writes `:failed`
and answers a durable parent as ADR-0008 decides, and `cancel/3` writes
`:cancelled`. So a cascading cancel (ADR-0008 decision 5) reaches a parked
child, and a host that gives up on a parked execution ends it without
migrating it first.

**3. It is left by a corrected plan, or by `Executions.unpark/3` onto its
own chart.** There are two ways out, and both are explicit calls:

- `migrate/4` with a plan that applies. It accepts an execution in
  `:needs_migration` as it accepts one in `:active`, and on success the
  execution is `:active` on the plan's target chart. A plan that fails
  again leaves it parked under `:park` and parked under `:refuse`.
- `StatifierPersistence.Executions.unpark/3` (store, execution id, opts)
  writes `:active` and nothing else: the execution goes on at the position
  it was parked at, on the chart it was already pinned to. It takes
  `serialization:`, as `cancel/3` does. On a terminal execution it answers
  `{:discarded, execution}`, as `fail/4` and `cancel/3` do; on an `:active`
  execution it answers `{:ok, execution}` and writes nothing, so re-running
  an interrupted unpark changes nothing.

Neither way out replays anything. A delivery refused while the execution
was parked is delivered again by the host or not at all.

**4. The drained query answers it under its own key, and it pins its
chart.** `t:execution_counts/0` gains `needs_migration`, so
`StatifierPersistence.Executions.executions_on/2` answers six keys: the
five stored arms and `children`. A parked execution pins the chart it is
parked on, the chart it was pinned to before the call that parked it.
Under this record ADR-0012 decision 1's first clause is read as an
execution row on that hash in the `:active` or the `:needs_migration` arm,
and its child clause as counting a
durable child's linkage pin while the parent is in either of those two
arms. Both follow from decision 3: an execution that `unpark/3` can put
back to work on its own chart needs that chart, and a parent that can take
a step again can read its child's pin again. ADR-0012 carries a dated Note
naming this change; the Note decides nothing, this record does.

The listing a pin source is handed
(`c:list_active_execution_ids_by_content_hash/2`) stays `:active` only. A
parked row already refuses a retirement through its own count, so a source's
view of it cannot change whether a retirement proceeds, and the listing's
meaning - fixed in a released version - is not widened for a count that is
reported and never decisive.

**5. What the arm does at each kind of site.** The rule is stated per kind
of site rather than as a complete list of a live codebase; the sites named
are the ones read at `9cd192b`.

- *Types and their documentation.* `t:execution_status/0` gains the arm;
  every typedoc or doc that lists the arms or says which are terminal says
  five arms and names `:needs_migration` as not terminal: the typedoc of
  `t:execution_status/0` (`adapter.ex:56`, @9cd192b), of
  `t:execution_counts/0` (`adapter.ex:128`, "The four arm keys", @9cd192b),
  the docs of `executions_on/2` and of
  `Storage.count_executions_by_content_hash/2`, and the `status` paragraph
  of `docs/telemetry.md` (step stop, @9cd192b).
  `t:StatifierPersistence.Execution.t/0` and `t:execution_state/0` widen
  with the type and need nothing of their own.
- *Stored-value vocabularies.* The Ecto adapter's `@statuses` gains
  `needs_migration: "needs_migration"`, and `encode_status/1` and
  `decode_status/1` follow from it. Without it every fetch, listing or
  count that reads a parked row raises on a missing clause.
- *Count vocabularies.* Every map that carries one key per arm gains
  `needs_migration`: `@zero_counts` in both adapters (`ecto.ex:69`,
  `in_memory.ex:40`, @9cd192b), which is what each adapter's
  `count_executions_by_content_hash/2` folds onto (`ecto.ex:554`,
  `in_memory.ex:362` in `execution_counts/2`, @9cd192b) - on the in-memory
  side it is also what keeps the fold's `Map.update!/3` from raising on the
  new status, and on the Ecto side the grouped count reads the new string
  through `decode_status/1`; the nested `executions` map of
  `t:pin_counts/0` and the key list `Adapter.pin_counts/3` takes
  (`adapter.ex:813`, `pin_counts/3`, @9cd192b).
- *Terminal guards.* The arm is not terminal wherever a terminal set is
  tested. `step_tail/7` gains a refusal arm for it ahead of its load
  (decision 2) - without one a parked execution would step, because its
  non-terminal arm loads and steps whatever is not in the terminal list.
  `fail_tail/3` and `cancel_tail/2` (`executions.ex:584`, `:625`, @9cd192b)
  keep their terminal-only discard, which is decision 2's proceed.
  `Driver`'s private `terminal?/1` (`driver.ex:1278`, @9cd192b) answers
  `false`, so a fan-out under `:all` does not settle while a child is
  parked, as it does not while one is `:active`.
- *Pin filters.* Every filter that reads "the parent is `:active`" or "an
  `:active` row on the hash" as a pin reads "`:active` or
  `:needs_migration`": `Adapter.pinned?/1` (`adapter.ex:836`, @9cd192b);
  the Ecto adapter's `children_pin_count/2`, `child_pins/2` and the
  tombstone's `unpinned_chart/2` (`ecto.ex:579`, `:878`, `:834`, @9cd192b);
  the in-memory `pinned_child?/3` (`in_memory.ex:395`, @9cd192b). The two
  pin-source listings (`ecto.ex:620`, `in_memory.ex:420`, @9cd192b) keep
  `:active` only, per decision 4.
- *Status producers and reporters.* No step produces the arm:
  `execution_status/2` (`executions.ex:1847`, @9cd192b) derives
  `:active`, `:completed` or `:failed` from a stepped position and never
  `:needs_migration`. `report_termination/5` and `report_halt/4`
  (`executions.ex:1396`, `:1567`, @9cd192b) treat the arm as they treat
  `:active` - nothing is terminated, nothing is reported - and no path
  reaches them with it today. `repair_terminal/4` is reached only after a
  load, which decision 2's refusal precedes. `Driver`'s `report_settled/3`
  (`driver.ex:1189`, @9cd192b) counts a parked child in none of its three
  terminal tallies, as it counts an `:active` one, and its private
  `maybe_answer_parent/3` answers a parent only for `:completed` and
  `:failed`, which a parked execution never is.
- *Tests that fix the vocabulary.* Every exact-key assertion on the drained
  query's answer gains the key - the conformance suite's two unknown-hash
  cases (`lib/statifier_persistence/testing/storage_conformance.ex:710`,
  `:1022`, @9cd192b) among them - and the conformance suite gains a parked
  execution's count and its pin. The test that enumerates the stored arms
  is the Ecto adapter's status round trip
  (`test/statifier_persistence/storage/ecto_test.exs:62`, "all three
  statuses round-trip and store ADR-0004's strings", @9cd192b), which the
  code half widens to every arm of the type. A site this list misses is
  held by the same rule: the arm is non-terminal, it pins, it is counted
  under its own key, and it takes no event.

**6. The arm is breaking for a host that matches the status exhaustively.**
A `case` over `t:execution_status/0` with four clauses and no catch-all
raises on a parked execution, and a host that pattern-matches the drained
query's answer as a closed five-key map no longer matches it. An adapter
outside this package that implements the drained query must count the new
arm and answer the new key, and one that stores the status must store the
new value. The release carrying the arm is a minor, and its changelog
fragment says it is breaking for exhaustive matchers and for those
adapters.

**7. No schema version.** The premise read found no constraint on the
column through V07, so the arm is a new string in an unconstrained `text`
column and needs no migration. Had the read found one, a version would
have been appended; it did not.

**8. What this record does not decide.** The plan format, both
validations and `migrate/4` itself are ADR-0013's. Migrating a tree of
executions together - a parent and its durable children - is not decided.
Nothing migrates an execution automatically, on a publish or at any other
time, and nothing here parks one automatically either. Queuing a refused
delivery inside this package, so that it is applied when the execution
leaves the arm, is not decided: this record refuses it whole and leaves the
retry to the host. Whether the park and the unpark emit telemetry of their
own is not decided here.

### A parked hold

A hold's execution waits in `awaiting_pickup` with its `pickup` timer
pending, while the library's hold document is edited: `awaiting_pickup`
becomes `ready_for_pickup`, and the step that routes the copy to the
pickup branch gains a `transferred` outcome. The host's first plan maps the
routing step and its new outcome but leaves `awaiting_pickup` unmapped.
`migrate/4` with `on_failure: :park` refuses it, because the execution's
active state does not resolve against the target chart, and parks it: the
execution is `:needs_migration`, still at `awaiting_pickup` on the old
chart, and `executions_on/2` on the old hash answers `needs_migration: 1`.
The old chart cannot be retired while it waits.

While it is parked the patron collects the copy, and `copy.collected` is
delivered. The delivery answers `{:error, {:needs_migration, execution}}`,
nothing is appended and nothing is stepped, and the host's job queue holds
it for a retry. The host corrects the plan, mapping `awaiting_pickup` to
`ready_for_pickup` with the `pickup` timer kept, and calls `migrate/4`
again. The execution is `:active` in `ready_for_pickup` on the new chart,
the retried `copy.collected` steps it, and the old hash's `needs_migration`
count is back to zero.

Had the host decided the edit should not reach this hold at all,
`Executions.unpark/3` would have put it back to `:active` in
`awaiting_pickup` on the old chart, and the retried delivery would have
stepped it there.

## Consequences

**The code half builds the arm, and parks nothing.** sp-3vv adds the arm,
handles it at every site decision 5 names and extends the conformance
suite; `migrate/4` stays the only writer of the arm, so its tests set the
status through the adapter. `Executions.unpark/3` ships no later than the
first release in which `migrate/4` can park, because without it the only exits from the
arm are a corrected plan or ending the execution, and a host that wants
the execution to go on unmigrated would have neither. No schema version ships with any of it.

**A refused delivery is the host's to keep.** Nothing in this package
holds an event for a parked execution. A host whose delivery path does not
retry on an error loses the delivery, and a durable child's automatic
answer to a parked parent is one such path: `Driver`'s automatic answer
returns the child's own result whatever the parent's door answered, so the
answer reaches the parent only when the host answers again through
`Driver.answer_parent/3` after the parent leaves the arm. The child's own
terminal status and recorded answer are durable either way. A delayed send
whose timer fires while its execution is parked is refused the same way,
and whether it survives depends on how its queue retries.

**Parking holds a chart.** A parked execution pins its chart for as long as
it stays parked, so a host that parks and forgets holds that chart's bytes
indefinitely. `executions_on/2`'s `needs_migration` key is how a host finds
them, and `fail/4`, `cancel/3`, `unpark/3` and a corrected `migrate/4` are
how it lets them go.

**ADR-0012's enumerations widen.** Its decision 2's four stored arms become
five, its decision 3's five-key map becomes six, and its decision 1's
blocking set keeps its four kinds with the first and second reading two
arms instead of one. The Note appended to ADR-0012 names each change and
points here.

**The release is a minor with a breaking entry.** Decision 6 is the
changelog's text: exhaustive matchers on the status or on the drained
query's answer, and adapters that implement the drained query or store the
status, must handle the new arm.
