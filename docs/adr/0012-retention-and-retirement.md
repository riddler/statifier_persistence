# ADR-0012: Retention and retirement: what pins a chart, zero pins is retirable, `Executions.retire_chart/4` refuses with the counts or tombstones the row and nulls the blobs, a retired hash is its own error, and no clock

Status: accepted (2026-09-20, sp-ryi, campaign RF063; proposed 2026-09-19 and
accepted once the code beads had landed against it. sp-9oa built the drained
query and migration V07, sp-34l built the pin-source behaviour, and
`Executions.retire_chart/4` follows both)

## Context

This package stores a chart once per content hash and has never taken one
back out. Charts accumulate for the life of the store: every chart a host
has ever saved stays, including the ones whose last execution finished months
ago. A host that authors charts from a UI reaches the point where it wants to
stop carrying the bytes of a chart nothing can resume, and today it has no
supported way to ask for that, and no way to ask the safer prior question -
*is anything still using this?*

The dangerous half is not the removal. It is removing a chart something can
still resume. A position is only ever loaded back through the identity guard
(ADR-0003 decision 2), so a missing chart does not corrupt an execution - it
strands it, permanently and silently, with a not-found arm that reads like a
bug. The design problem is therefore to name, as a rule, exactly what counts
as still using a chart, and to make the removal refuse loudly and completely
when any of it is true.

### The premise surface

Everything below rests on `statifier_persistence` `main` at **`a1a83a2`**
(`a1a83a2` = "Pins step/5 under a held lock, per adapter"), read 2026-09-19.
Every code cite in this record carries that SHA and an anchor beside its line
number, because line numbers move and anchors do not.

- **A chart is keyed by its content hash, and the key is unique.** The
  `charts` table declares `add(:content_hash, :text, null: false)` and
  `create(unique_index(charts, [:content_hash], prefix: config.prefix))`
  (`lib/statifier_persistence/ecto/migrations/v01.ex:43`, `:49`, @a1a83a2).
  One row per hash: a retirement is a decision about a row and about a hash
  at the same time.
- **There are two chart doors.** `Storage.save_chart/3`
  (`lib/statifier_persistence/storage.ex:143`,
  `def save_chart(%__MODULE__{} = store, %Machine{} = machine, chart_blob)`,
  @a1a83a2) and `Storage.fetch_chart/2` (`storage.ex:167`,
  `def fetch_chart(%__MODULE__{} = store, content_hash)`, @a1a83a2). The miss
  arm is `:chart_not_found`
  (`lib/statifier_persistence/storage/adapter.ex:200`, in this layer's own
  refusal arms, @a1a83a2).
- **`positions` is a third table on the same hash.** `v01` creates it beside
  `charts` and `executions`, with `add(:content_hash, :text, null: false)`
  and `add(:position_blob, :binary, null: false)` of its own, keyed by
  `create(unique_index(positions, [:session_id], prefix: config.prefix))`
  (`ecto/migrations/v01.ex:53`..`:62`, @a1a83a2). It is written by
  `Storage.save_position/3` (`storage.ex:189`, @a1a83a2) and read by
  `Storage.load_position/3` (`storage.ex:252`, @a1a83a2). Its key is the
  session, not the execution, so it is disjoint from `executions`: a hash
  can carry position rows and no execution row at all, and nothing in the
  executions tables reveals them.
- **No removal verb exists on this package's surface.** Read at @a1a83a2,
  `lib/` carries no delete, retire, tombstone or purge door of any kind; the
  only removals in the tree are two migration `remove/1` calls inside a
  schema change (`ecto/migrations/v02.ex:43`, `v03.ex:119`, @a1a83a2). So
  this record introduces a removal verb together with its refusal, in one
  decision, rather than adding a refusal to a verb that already shipped.
  Keeping that true as the package grows is a test's job, not this record's.
- **A stored execution's status has four arms.**
  `@type execution_status :: :active | :completed | :failed | :cancelled`
  (`storage/adapter.ex:62`, @a1a83a2). Every execution row also carries the
  hash of the chart it runs: `add(:content_hash, :text, null: false)` on the
  `executions` table (`ecto/migrations/v01.ex:70`, @a1a83a2).
- **A durable child carries a mandatory chart pin in its linkage.**
  `@enforce_keys [:parent_execution_id, :invoke_id, :child_index, :content_hash]`
  (`lib/statifier_persistence/execution/linkage.ex`, `@enforce_keys`,
  @a1a83a2), stored under this package's reserved metadata key
  (`linkage.ex`, `reserved_key/0`, @a1a83a2). ADR-0008 decision 2 hardens
  that pin into contract: it is what stands between resuming the workflow the
  parent started and resuming a different one that happens to share an id.
- **The blob columns are not nullable today.** `charts` declares
  `add(:identity_blob, :binary, null: false)` and
  `add(:chart_blob, :binary, null: false)`
  (`ecto/migrations/v01.ex:44`, `:45`, @a1a83a2), and no migration after
  `v01` alters `charts` at all (the whole DDL is `v01.ex`..`v06.ex`,
  @a1a83a2). Dropping a chart's bytes while keeping its row is therefore not
  executable against today's schema without a migration, which is why
  decision 6 names one.
- **`executions.content_hash` is unindexed.** `v01` indexes `execution_id`
  (`ecto/migrations/v01.ex:80`, @a1a83a2) and `v03`/`v04` index `metadata`;
  no migration indexes `content_hash` on `executions` (@a1a83a2). A query
  that counts executions per hash needs one.
- **Optional adapter capability has an established shape.** An adapter opts
  in by exporting a callback, the facade checks with `function_exported?/3`,
  and a `supports_*?/1` predicate declares it - `supports_metadata?/1`
  (`storage/adapter.ex:406`, @a1a83a2) is the pattern, and
  `list_executions_by_metadata/2` (`:422`) and
  `list_execution_states_by_metadata/2` (`:466`) are the listings that use
  it.
- **Not every pin is in this package's tables.** Pending timers live in
  `statifier_oban` and address rows live in `statifier_router`. Both can hold
  a reason to resume an execution, and neither is visible from here. This
  package cannot count every pin from its own tables, and acquiring a
  dependency on either to try would invert the family's layering.

## Decision

**1. Four things pin a chart, and a child's pin counts while its parent is
`:active`.** A content hash is pinned when any of the following is true:
an execution row on that hash is in the `:active` arm; a durable child's
linkage pin names that hash and the execution named by that child's
`parent_execution_id` is in the `:active` arm, *whatever arm the child itself
is in*; a position row is stored on that hash; or a registered pin source
reports a non-zero count for it (decision 4). Those four are the blocking
set, and nothing else is in it: a non-zero count in any of the four refuses
a retirement, and an execution in a terminal arm pins nothing at all. A
terminal row never goes away, so counting one as a pin would make a chart
permanently unretirable the first time anything on it finished, which is the
opposite of what retirement is for; the terminal counts are reported in a
refusal (decision 5) because they tell the caller what the chart's history
was, and they never cause one. The position clause is here because a
position row is a saved session waiting to be resumed through
`load_position/3`, which needs the chart's bytes to resume against;
positions are keyed by session and disjoint from `executions`, so a hash
with no execution row at all can still hold live positions, and retiring it
would strand exactly the sessions this record's Context calls the dangerous
half. The child clause is deliberately not conditioned on the child's
own arm, because a child that has already finished is still reachable: under
ADR-0008 a completion is placed at the child's index by whatever node picks
it up, and the pin is the value that guard compares. While the parent can
still take a step, the child's pin can still be read, so the child's chart is
still in use. A child whose parent has reached a terminal status pins
nothing, because no path re-reads its pin. An `:active` child is already
pinned by its own row under the first clause; the child clause exists exactly
for the terminal child of a live parent.

**2. "Terminal" is this record's word for the fold of `:completed`, `:failed`
and `:cancelled`, and it is never a stored value.** The stored arms are
`:active`, `:completed`, `:failed` and `:cancelled` and no others; no column
holds the string `terminal`, no function returns `:terminal` as an arm, and
no adapter is asked to store it. It is vocabulary for reading this record and
for naming the fold in prose, and the four arms remain the contract
everywhere a status is written, matched or compared.

**3. The drained query answers, for one hash, a count per stored arm plus
children, and an adapter that cannot answer it says so.** A new adapter
callback, `count_executions_by_content_hash/2`, takes the adapter opts and a
content hash and returns
`{:ok, %{active: n, completed: n, failed: n, cancelled: n, children: n}}`,
where the four arm keys count execution rows on that hash and `children`
counts the linkage pins decision 1 counts - pins naming that hash whose
parent is `:active`. Its facade is
`StatifierPersistence.Storage.count_executions_by_content_hash/2` and its
public entry is `StatifierPersistence.Executions.executions_on/2`, which sits
beside `Executions.inputs/2` as a listing entry over a Storage call. An
adapter declares the capability the way the optional callbacks already do:
it exports the callback, the facade checks with `function_exported?/3`, and
`supports_content_hash_query?/1` is the predicate a host can ask directly.
An adapter that does not export it cannot be retired against, and
`Storage.retire_chart/3` refuses at open rather than retiring on a count it
could not take.

**4. A pin source is a behaviour a host implements, and this package gains no
dependency for it.** `StatifierPersistence.PinSource` declares one callback,
`pins(content_hash, context)`, returning a map of atom to non-negative
integer - the source's own named counts. `context` carries the ids of the
`:active` executions on that hash, because a source such as a timer queue
knows executions and never knows hashes, and giving it the ids is what lets
it answer without learning this package's key. This package implements no
source and depends on no package that would be one; a host passes the list of
source modules to the retire call. A source that raises is a refusal, never a
zero: the retirement stops with the failing module named, because "the source
could not answer" and "the source answered zero" are different facts and
collapsing them would retire a pinned chart.

**5. Zero pins means retirable; a non-zero count anywhere in decision 1's
blocking set refuses, and the refusal carries every count by name.** The
host-facing entry is `StatifierPersistence.Executions.retire_chart/4`,
taking the store, the content hash, the list of pin-source modules and
options carrying the retiring actor; the facade beneath it is
`StatifierPersistence.Storage.retire_chart/3`, taking the store, the content
hash and options. The split follows decision 3's layering:
`Executions` is the host-facing entry and owns what reaches outside this
package - it calls each pin source and holds decision 4's refusal for a
source that raises - while `Storage` is the facade over this package's own
tables and owns the transaction, the counts taken inside it, and the
tombstone write. Exactly decision 1's four pin kinds refuse: a non-zero
`active`, a non-zero `children`, a non-zero position count, or a non-zero
count from any source. The drained query's three terminal arms are reported
and never refuse. The position count is deliberately not in decision 3's
map; the retire call counts position rows on the hash inside the transaction
it already opens. Whatever the reason for the refusal, it carries all of the
counts - this package's own under its own name and each source's under that
source's module name - so the caller learns everything holding the chart in
one answer rather than one refusal per retry.

**6. A successful retirement tombstones the row and nulls the blobs in one
transaction with the count it was decided on; `fetch_chart/2` then answers a
distinct retired error, and `save_chart/3` refuses.** The row keeps its
content hash and gains `retired_at` and `retired_by`; the removal itself is
nulling `identity_blob` and `chart_blob` on that row, and migration V07 makes
both columns nullable so it can happen at all (decision 6's mechanism is
forced by the schema cited above, not chosen). The tombstone write and the
count it rests on are one transaction, so a pin appearing between the count
and the write loses the race rather than being retired out from under.
`fetch_chart/2` on a tombstoned hash answers a retired error carrying who
retired it and when, never `:chart_not_found`, because a host that asked for
this removal deserves to read its own decision back rather than a miss it
will debug as data loss. Saving a chart whose hash is tombstoned **refuses
with that same retired arm and does not revive the row**: reviving would put
a chart back into service under a hash whose row still asserts, in
`retired_at` and `retired_by`, that somebody decided it was done, and a
content-addressed save is the one call with no way to express "yes, I mean to
undo that" - it looks identical to an ordinary idempotent re-save. The
refusal is the same answer read from the guard's side, and the guard itself
is untouched: ADR-0003 decision 2's identity guard reads the *position*
row's own identity blob and compares it against the caller's machine, it
never reads a `charts` row, and a retirement writes no position row - so the
guard goes on comparing exactly what it always compared. What a retirement
changes is the chart doors' contract, and it changes it by adding an arm
rather than weakening one: the retired arm is checked and answered *first*
on both chart doors, before any identity or byte-identity obligation
applies. The adapter contract that a fetched
`identity_blob` is byte-identical to what `save_chart/2` was given
(`storage/adapter.ex:239`, @a1a83a2) is a statement about a chart the adapter
holds; a tombstoned row is not one, and no call returns a chart record whose
blobs are `nil`. The two sides therefore agree: after a retirement the hash
is terminal on every door.

**7. There is no clock in this package.** When a chart should be retired is
host policy. This record names no number of days, no age, no retention
window and no default, no call takes a duration, and nothing here retires on
its own or on a schedule. The package answers "is it pinned" and performs a
retirement it was asked for; deciding when to ask is the host's, and a host
that wants a sweep writes one over `Executions.executions_on/2` and acts on
what it finds through `Executions.retire_chart/4`.

**8. Three things are not decided here.** Purging a finished execution's
position and input log is a separate design bead and is not in scope: this
record retires charts, and an execution's own rows are untouched by every
decision above. Moving an execution to another chart is not decided here
either. And no un-retire verb is decided: decision 6 refuses a revive through
`save_chart/3`, and whether an explicit door should exist to reverse a
tombstone is left open rather than answered by omission.

## Consequences

**Migration V07 carries five changes, and one bead owns it.** An index on
`executions(content_hash)`, which the drained query needs and which nothing
provides today; the two tombstone columns on `charts`, `retired_at` and
`retired_by`; and two `modify(..., null: true)` changes, on
`charts.identity_blob` and `charts.chart_blob`, without which decision 6's
nulling cannot execute. Its `down/1` reverses all five, which means a
down-migration over a store holding a tombstoned row cannot restore
`null: false` while that row exists - the down refuses rather than
inventing bytes, and that refusal is part of what V07's bead builds.

**The pin set and the drained query's map deliberately differ.** The drained
query answers "what is running on this chart" and keeps the five keys
decision 3 names. The retire refusal answers "what would I break", and it
reports more than those five keys: it adds the position count decision 5
takes inside the transaction and every registered source's counts. What it
*blocks* on is narrower than either, and is decision 1's blocking set
unchanged - a non-zero `active`, a non-zero `children`, a non-zero position
count, or a non-zero count from any source. The three terminal arms are
reported and never block, here as in decisions 1 and 5. So the drained
query is not a retirability test on its own and nothing should read it as
one - a host asks it to see a chart's traffic, and asks
`Executions.retire_chart/4` whether the chart can go. The position count
stays out of the callback's map so the adapter surface does not grow a
second query for it; the retirement takes that count inside its own
transaction instead.

**The adapter behaviour grows one callback and one predicate.**
`count_executions_by_content_hash/2` and `supports_content_hash_query?/1`
join `@optional_callbacks`. Every adapter written before this record stays
conformant without a line of change: it exports neither, the facade finds
neither, and only `Storage.retire_chart/3` refuses on the absence. The
conformance suite gains cases for the counts in each arm, for the child
clause of decision 1 (a terminal child under an `:active` parent counts; the
same child under a terminal parent does not), and for an adapter that
declines the capability.

**A new behaviour module ships.** `StatifierPersistence.PinSource`, with one
callback and no implementation in this package, plus a test double in the
test tree standing in for a host's timer queue - including one that raises,
pinning decision 4's refusal.

**`fetch_chart/2` gains an error arm and `save_chart/3` gains a refusal.** A
host matching exhaustively on either door sees a new arm, so the release
carrying this is a minor and its changelog fragment says so under Added and
Changed. `:chart_not_found` keeps its meaning exactly: never stored, as
against stored and retired.

**Retirement is irreversible through the public surface.** Decision 6 refuses
the revive and decision 8 leaves the un-retire door undecided, so a host that
retires a hash it still wanted must re-author the document and save the
resulting chart under a new hash.
That is the cost of the refusal being unambiguous, and it is named here so
the next record that wants to reverse it knows what it is reversing.

## Note (2026-09-19, sp-34l): a malformed answer is a second refusal beside the raise, and `PinSource.collect/3` is where decision 5's walk lives

Pure addition: nothing above is edited, and this record is read at the date
its sections were decided.

**A source whose answer cannot be read refuses too, under the reason
`:invalid_return`.** Decision 4 decides one failure - a source that raises is
a refusal, never a zero - and leaves a second one open: a source that returns
anything other than a map of atom to non-negative integer. That is decided
here, the same way and for the same reason. "The source could not answer" and
"the source answered zero" are different facts, and collapsing them retires a
pinned chart; a return the callback's own type rules out is the first of
those two facts wearing the shape of the second, which makes it the more
dangerous of the pair, not the more forgiving. So the collection stops with
the failing module named, exactly as a raise stops it, and the two reasons
stay distinguishable to the caller: `{:raised, exception}` for the one
decision 4 names and `{:invalid_return, value}` for the one this Note names
(`@type reason`, `lib/statifier_persistence/pin_source.ex`, read at
`60ca172`). A refusal is never a count, so neither reason ever reaches the
retire door as a zero.

**Decision 5's walk is public, and it lives on
`StatifierPersistence.PinSource.collect/3`.** Decision 5 gives
`Executions.retire_chart/4` the job of calling each pin source and holding
the refusal for a source that raises; it does not say where the calling
itself lives, and this Note says. `collect/3` takes the host's list of source
modules, the content hash and the context, and answers either every source's
counts keyed by that source's module or the first refusal
(`lib/statifier_persistence/pin_source.ex`, `collect/3`, read at `60ca172`).
`Executions.retire_chart/4` takes its source counts from that function rather
than walking the list itself, so the refusal rules above hold at the one
place, for that door and for any later caller. That the walk is public is the
decision: a host may ask what its own sources say about a hash without asking
for a retirement.

## Note (2026-09-19, sp-brx): retirement needs a store whose chart blobs are nullable, and a source that could not answer refuses without counts

Pure addition: nothing above is edited, and this record is read at the date
its sections were decided.

**The Consequences sentence "Migration V07 carries five changes" is
unconditional; two of those five are not.** V07's two
`modify(..., null: true)` calls, on `charts.identity_blob` and
`charts.chart_blob`, are guarded to Postgres, because `ecto_sqlite3` raises
`ArgumentError` from `modify/3` rather than emitting an `ALTER COLUMN` SQLite
does not have, and dropping the constraint otherwise means rebuilding the
table and copying every row into the copy - which this package's DDL has
never done to a host's data
(`lib/statifier_persistence/ecto/migrations/v07.ex`, `up/1` and its
"Adapters other than Postgres" section, read at `ab67d62`). So on a backend
that is not Postgres the two blob columns keep the `null: false` V01 gave
them, and decision 6's nulling cannot execute there.

What follows for decision 5's entry, and it is the point of this Note:
**retirement requires a store whose chart blobs are nullable, and a store
where they are not is refused at open rather than allowed to reach a
constraint violation.** The refusal names the backend limit, because "this
store cannot carry a tombstone" and "this package malfunctioned" read the
same way out of a database error and are not the same fact - the same
distinction decision 4 draws between a source that could not answer and a
source that answered zero. A store is asked, not a backend: a host that
altered the two columns itself, in a migration of its own, has a store that
can be retired against, and the answer follows the columns rather than the
adapter module. Nothing else in this record is affected - the drained query,
the pin counting and both chart doors behave identically on every backend.

**A refusal caused by a source that could not answer carries no counts, and
it is not the pinned arm.** Decision 5 says a refusal "carries all of the
counts"; decision 4 says a source that raises "stops with the failing module
named"; the pin-source walk this record's sp-34l Note makes public halts at
the first failure and collects nothing after it. The three cannot all hold,
and this Note says which gives way: decision 5's sentence is about a refusal
that knows all of the counts, which a stopped walk does not. So the two
refusals are two arms. A pin refusal carries every count. A source-failure
refusal carries the failing module and its reason, and no count map at all.

Reporting the counts the walk did reach would be friendlier, and that is
exactly the hazard: those counts are not all of them, they would arrive in
the shape that elsewhere means all of them, and a host reading a partial
count as complete is the one mistake decision 4 exists to prevent. An
incomplete count is not a smaller answer to the same question; it is an
answer to a different one. Making the two arms structurally different is
what keeps a host from having to know the difference.

**Decision 3's capability now covers two callbacks, and an adapter that
declares it exports both.** Decision 3 rules that an adapter declares the
drained query by exporting one callback beside the predicate - "it exports
the callback, the facade checks with `function_exported?/3`". Decision 4
gives a pin source the ids of the `:active` executions on the hash, and
decision 3's map holds counts and no ids, so the ids need a listing of their
own; that listing,
`list_active_execution_ids_by_content_hash/2`, is placed under
`supports_content_hash_query?/1` rather than under a second predicate. Both
read the same column under the same index, and an adapter has no way to
want one and not the other. The consequence is a real widening of what the
predicate promises: an adapter that answers `true` is called for both, so an
adapter written to decision 3 exactly as ruled - the predicate and the count
callback and nothing further - is no longer conformant, and exports the
listing too.

**Widening it rather than adding a second opt-in is safe only because the
capability is unreleased, and that will not be true a second time.** Neither
`supports_content_hash_query?/1` nor `count_executions_by_content_hash/2`
exists at tag `v0.12.0`, the latest released version (verified by searching
that tag's tree); both landed in the same unreleased cycle as the listing,
and `0.13.0` has not been cut. So no adapter outside this repository can have
declared the capability yet and nothing can be broken by changing what it
means. Once `0.13.0` ships, the same widening is a breaking change to every
adapter that declared the capability, and the answer then is a second
predicate rather than a second callback under the first.

**The Consequences sentence "The adapter behaviour grows one callback and
one predicate" counted this record's first pass, not its whole.** It is
exact about the two it then names. Read as a total it is now inexact: the
behaviour grows three callbacks - `count_executions_by_content_hash/2`,
`list_active_execution_ids_by_content_hash/2` and `retire_chart/3` - and two
predicates, `supports_content_hash_query?/1` and
`supports_chart_retirement?/1`. The sentence's substance survives
unchanged, because what it is really saying is that every adapter written
before this record stays conformant without a line of change: it exports
none of the five, the facade finds none, and only the retirement refuses on
the absence.

## Note (2026-09-19, sp-7av): a create on a tombstoned hash is refused, there is no un-retire door, and the facade takes the source counts it is handed

Pure addition: nothing above is edited, and this record is read at the date
its sections were decided.

**Creating an execution on a tombstoned hash is refused, with decision 6's
own retired arm.** Decision 6 changes the two chart doors and decision 1
names what pins a chart; neither reaches the door that makes a new
execution. `StatifierPersistence.Executions.create/4` derived its content
hash from the machine it was handed and wrote an execution row carrying that
row's own identity and position blobs, and nothing in it read a `charts` row
- the state this Note changes (`lib/statifier_persistence/executions.ex`,
`create/4`, read at `49f7ffc`).
A retirement refuses for as long as anything in decision 1's blocking set
pins the hash, so every execution that existed before a successful
retirement is safe; an execution created after one is not, and it is
unresumable from the moment it is durable, because its chart is read back
through `fetch_chart/2`, which answers the retired arm. So `create/4`
answers `{:error, {:chart_retired, info}}` for a tombstoned hash, before it
writes anything and before any effect is executed - the refusal-at-open
ordering ADR-0006 decision 3 set for metadata, for the same reason. The arm
is decision 6's and not a second spelling of it: a host that already matches
the retired arm on the chart doors matches this one unchanged.

Where the check lives follows decision 5's split, and it is the facade:
reading the tombstone is a read of this package's own tables, so
`StatifierPersistence.Storage.check_chart_retired/2` owns it and the
host-facing entry calls it (`lib/statifier_persistence/storage.ex`,
`check_chart_retired/2`, read at `f6f0b1f`). A hash this store never held is
not a retired hash: `:chart_not_found` keeps the meaning decision 6 gave it,
and a host may still create an execution on a machine whose chart it never
saved. The refusal costs each create one read of the chart row; as
implemented that read transfers the chart's stored bytes, so its cost
scales with the size of the chart until a narrower read exists. That cost
is part of the decision rather than an accident of it: an execution that
can never be resumed is the more expensive of the two.

**Retirement is permanent through this package's public surface, and that is
now decided rather than left open.** Decision 8 leaves it undecided whether
an explicit door should exist to reverse a tombstone. There is none, and
none is coming: no call in this package reverses a retirement, and a host
that retires a hash it still wanted re-authors the document and saves the
result under its new hash, which is a different hash and therefore a
different chart. The execution rows that named the old hash go on naming it,
and it stays terminal on every door. The Consequences section already reads
that consequence off decision 6's refusal to revive; what it could not say,
with decision 8 open, is that the door itself is refused, and this Note says
it. The reason is the one decision 6 gives for refusing the revive: a
retirement is a host's own recorded decision, and a package that offers to
undo it makes every other refusal in this record conditional on whether the
caller also knows about the undo.

**The facade takes its caller's source counts on trust, and a caller that
reaches past the host-facing door takes the outside half with it.** Decision
5 makes `StatifierPersistence.Storage.retire_chart/3` public and gives it
this package's own tables; the pin sources belong to
`StatifierPersistence.Executions.retire_chart/4`, and their counts arrive at
the facade as the `source_counts:` option, defaulting to `%{}`
(`lib/statifier_persistence/storage.ex`, `retire_chart/3`, read at
`f6f0b1f`). So a host calling the facade directly decides its retirement on
decision 1's first three pin kinds alone, and a host passing `%{}` while its
own sources hold counts retires a chart its own sources would have blocked. That is the split working as
designed and not a hole in it - the facade is documented for a host that
keeps its own pin accounting and has already done the outside half itself -
and it is recorded here because it was unrecorded, not because it changes.

## Note (2026-09-23, sp-6pa): the sp-brx Note's closing clause names one refusal where there are several, and its heading leaves out the capability widening

Pure addition: nothing above is edited, and this record is read at the date
its sections were decided. This Note decides nothing; it qualifies two
places in the sp-brx Note whose wording is looser than what they record.

**"Only the retirement refuses on the absence" is inexact about which
functions refuse.** The sp-brx Note's last paragraph says that an adapter
written before this record exports none of the new callbacks, the facade
finds none, "and only the retirement refuses on the absence". Every facade
function that needs the drained query answers
`{:error, :content_hash_query_unsupported}` when the adapter does not
declare it, without calling the adapter's query callback:
`Storage.count_executions_by_content_hash/2`
(`lib/statifier_persistence/storage.ex`, `count_executions_by_content_hash/2`,
read at `fb1bae9`), `Storage.list_active_execution_ids_by_content_hash/2`
(same file, `list_active_execution_ids_by_content_hash/2`, read at
`fb1bae9`) and `Storage.retire_chart/3` (same file, `retire_chart/3`, read
at `fb1bae9`), which also answers `{:error, :chart_retirement_unsupported}`
for a store that cannot carry a tombstone. The host-facing doors above them
answer the same arms: `Executions.executions_on/2`
(`lib/statifier_persistence/executions.ex`, `executions_on/2`, read at
`fb1bae9`) and `Executions.retire_chart/4` (same file, `retire_chart/4`,
read at `fb1bae9`). The sentence's substance is unchanged: an adapter
written before this record stays conformant without a line of change,
because each of those answers is a refusal at open and none of them is a
conformance failure. The looseness is inherited from the Consequences
paragraph "The adapter behaviour grows one callback and one predicate",
whose "only `Storage.retire_chart/3` refuses on the absence" the sp-brx
Note repeated rather than qualified.

**The sp-brx Note's heading names two of its topics and leaves out a
third.** The heading names the nullable chart blobs and the source that
could not answer. The third topic is in the Note's closing paragraphs: that
decision 3's capability covers two callbacks rather than one, why widening
it was safe before `0.13.0` and would not be again, and the corrected totals
of callbacks and predicates. A reader scanning the headings for where the
capability's scope was settled finds it under the sp-brx Note.

## Note (2026-09-23, sp-zf8): a fifth stored arm, `:needs_migration`, adds a key to the drained query and pins its chart

Pure addition: nothing above is edited, and this record is read at the date
its sections were decided. This Note decides nothing; ADR-0014 (the fifth
execution status, proposed) does, and this Note names where it reaches the
enumerations above.

**Decision 2's four stored arms become five.** ADR-0014 decision 1 adds
`:needs_migration`, the status a parking migration writes. It is outside
the terminal fold: `:completed`, `:failed` and `:cancelled` remain the only
arms decision 2's word covers.

**Decision 3's map gains a sixth key.** `count_executions_by_content_hash/2`
and `Executions.executions_on/2` answer `needs_migration` beside the four
arm keys and `children` (ADR-0014 decision 4).

**Decision 1's blocking set keeps its four kinds, and two of them read two
arms.** An execution row on the hash in `:active` or `:needs_migration`
pins it, and a durable child's linkage pin counts while its parent is in
either arm (ADR-0014 decision 4). The listing handed to a pin source
(`list_active_execution_ids_by_content_hash/2`) stays `:active` only; the
three terminal arms still pin nothing.
