# ADR-0010: The durable per-run input log: two optional adapter callbacks, a verbatim event stamped with its door and its ordinal, a host-declared cap, one log per run

Status: accepted (2026-09-06, sp-t12; proposed the same day as sp-o1b under
campaign-034 ruling RQ-034-3, flipped once sp-80g landed - the Note below
names the merge and the four places the code diverged from this text)

## Context

`StatifierUI.Trace.Replay.from_events/4` replays a run offline, with no
session process and no clock: it takes the compiled chart, the session
options the run was made under, and the run's inputs as
`t:Statifier.Session.Recording.entry/0` values in the session's serialized
input order (`statifier-ui`'s `docs/ops-embedding.md`, "From a persisted
event log"). A live `Statifier.Session` can produce that list because it
records every input it serializes - `Recording.put_event/3`,
`put_invoked_event/4`, `put_timer/3`, `put_interpret/3`, `put_internal/6`.

A durably stepped run cannot. This package stores three things - a chart, a
position, and a run record - and none of them is an input. `Storage.Adapter`
has fourteen callbacks (`init/1`, `save_chart/2`, `fetch_chart/2`,
`save_position/2`, `fetch_position/2`, `insert_run/2`, `fetch_run/2`,
`update_run/2`, `isolate/1`, `lock_run/3`, `supports_metadata?/1`,
`list_runs_by_metadata/2`, `supports_run_outcome?/1`,
`list_run_states_by_metadata/2`) and not one of them appends an event.
`position_blob` is the run's *current* configuration, overwritten on every
step by construction (`save_position/2`'s "a session has exactly one current
position; this layer keeps no history"), so the history a replay needs is
destroyed by the mechanism that makes the run durable. `outcome_blob` is one
answer, written once at a terminal status. There is nowhere an event has ever
been stored.

That gap is what `sp-2sg` was filed for, out of a `statifier_examples`
worker's stop-and-report: the reference embedder's Run pane over a replayed
run has no log to replay. It is not an embedder-side gap. A host driving this
package hand-rolls nothing else about the loop - the exclusion, the identity
guard, the effect seam and the persist are all here - and an input log kept
beside the package would have to reproduce this package's serialization to be
correctly ordered at all, since the only place a run's inputs are known to be
serialized is inside the per-run exclusion this package holds
(`Runs.serialized/5`, ADR-0004 decision 5).

Facts about this package that bound the answer:

- **The door vocabulary already exists.** `t:StatifierPersistence.Runs.entry/0`
  is "the fixed vocabulary of public doors": `:create`, `:step`,
  `:done_invocation`, `:failed_invocation`, `:answer_parent`, `:fail`,
  `:cancel`. It is threaded to every serialized unit today as the `entry:`
  option, documented as telemetry-only (ADR-0009, `docs/telemetry.md`). Every
  public door in this package resolves to one of those seven atoms:
  `Runs.create/4`, `Runs.step/5`, `Runs.fail/4`, `Runs.cancel/3`,
  `Driver.create/3`, `Driver.send_event/4`, `Driver.done_invocation/5`,
  `Driver.failed_invocation/5`, `Driver.answer_parent/3` and
  `Driver.start_child_at/6`. The `Driver` doors are not separate write sites:
  each funnels into `Runs.step/5` or `Runs.create/4` and stamps its own
  `entry:` on the way (`driver.ex`'s `entry: :answer_parent`).
- **Only two doors carry an event into an interpreter.** `Runs.step/5` does,
  and everything the `Driver` builds - `done.invoke.<invoke_id>`,
  `error.communication.invoke.<invoke_id>`, a child's answer to its parent -
  arrives through it. `Runs.create/4` runs `Interpreter.initialize/2`, which
  takes no event. `Runs.fail/4` and `Runs.cancel/3` are host-driven terminal
  transitions that involve no interpreter at all (ADR-0009 decision 3).
- **The package already stores host-opaque terms as blobs.** `outcome_blob`
  is `:erlang.term_to_binary/1` of a `donedata` payload, encoded above the
  adapter (`driver.ex`'s `encode_outcome/1`). ADR-0003 decision 1 says every data-bearing
  callback takes and returns binaries plus engine identity strings, and its
  2026-08-29 amendment admits one optional opaque metadata map beside them;
  the encode-above-the-adapter shape is how a term reaches storage without
  widening either.
- **`:blob_type` reaches exactly three columns** - `identity_blob`,
  `chart_blob`, `position_blob` - and deliberately does not reach the
  `metadata` map, which ADR-0006 decision 2 therefore restricts to host
  identities and never personal data.
- **A run may be driven with a `routes:` snapshot.** `t:Runs.opt/0` carries
  `{:routes, MachineState.routes()}`, and st-ADR-0048 decision 3 has each
  recorded entry carry the snapshot its drive was judged against. This
  package stores no snapshot anywhere today.
- **Optional capabilities have a settled shape here.** `isolate/1`,
  `lock_run/3`, `supports_metadata?/1`, `supports_run_outcome?/1` and
  `list_run_states_by_metadata/2` are all `@optional_callbacks` opted into by
  export plus `function_exported?/3`, with `supports_*?/1` as the declared
  capability question. An adapter written before any of them is conformant
  unchanged.

This record decides the seam. The code - the callbacks, the Ecto
implementation on Postgres and SQLite, the write at every door, the cap and
the conformance cases - is `sp-80g`, and this record is the specification it
is written against.

**Note (2026-09-06, `sp-t12`):** `sp-80g` has landed - `27a7a15` on `main`,
PR 76 - and this record is accepted as of that merge. Every claim above and
below was re-read against `main` at `27a7a15` before the flip, and it holds
as written except in four places, each of which carries its own dated Note
where it stands rather than being edited into the text: the public
capability predicate's spelling (decision 1), the column count
`input_blob` joins (decision 4), where in the step the append actually
happens (decision 5), and two shapes the record left to the implementer
that are worth naming now they exist (decision 9). None of the four changes
what was decided; they record what the decided thing is called and where it
sits.

## Decision

### 1. The input log is a storage-adapter seam in this package, optional by export

The log is `Storage.Adapter`'s, not the host's. The ordering a replay depends
on is only knowable inside the per-run exclusion this package holds, and a
host keeping its own log outside it would be reimplementing
`Runs.serialized/5` to get the order right.

It is optional, in exactly the shape `supports_metadata?/1` and
`supports_run_outcome?/1` already use: an adapter opts in by exporting
`supports_input_log?/1` and answering `true`, the facade checks with
`function_exported?/3`, and an adapter that does not export it stores no
inputs and sees no behaviour change. `StatifierPersistence.Storage.InMemory`
and every adapter written before this record stay conformant without a line
of change.

**No run-lifecycle call refuses on it.** This is the deliberate departure
from ADR-0006 decision 3, whose `{:error, :metadata_unsupported}` refuses a
create at open, and from `start_child_at/6`'s `{:refused,
:run_outcome_unsupported}`. Both of those refuse because something the host
*asked for* would otherwise be silently dropped - a metadata map it supplied,
a child answer it will later have to read back. Nothing about the input log
is like that: it is a derived record of inputs the host is supplying anyway,
and refusing to run a chart because the log cannot be kept would let a
diagnostic facility break the run it is diagnosing. A host that needs to know
asks `StatifierPersistence.Storage.supports_input_log?/1`, which is public
for that purpose.

**Note (2026-09-06, `sp-t12`):** that public predicate shipped as
`StatifierPersistence.Storage.input_log_supported?/1`, not
`supports_input_log?/1`. The shape this paragraph holds up as the model has
two sides, and `supports_metadata?/1` is only the adapter's: the facade
side of it is `Storage.metadata_supported?/1`, the passive spelling
`storage.ex` already uses for the question a host asks. `sp-80g` matched
both sides rather than putting a second facade spelling one function away
from the first. The
*callback* keeps this record's name: an adapter still opts in by exporting
`c:StatifierPersistence.Storage.Adapter.supports_input_log?/1` and
answering `true`. Everything decided here - public, checked with
`function_exported?/3`, refusing at no door - is what shipped.

### 2. Two callbacks and one capability question, named

```elixir
@typedoc """
A run's input log ordinal: dense, zero-based, per run, assigned by the
adapter. Not a position blob.
"""
@type seq :: non_neg_integer()

@typedoc "The public door an input entered by (`t:StatifierPersistence.Runs.entry/0`), as a string."
@type door :: String.t()

@typedoc """
One stored input: the run it belongs to, its ordinal, the door it entered
by, and the opaque `input_blob` the facade encoded above this layer. A
`nil` `input_blob` is the closed marker of decision 6 and nothing else.
"""
@type input_record :: %{
        run_id: run_id(),
        seq: seq(),
        door: door(),
        input_blob: binary() | nil
      }

@callback supports_input_log?(opts()) :: boolean()

@callback append_input(opts(), run_id(), input_record()) ::
            {:ok, seq()} | {:error, error()}

@callback list_inputs(opts(), run_id()) ::
            {:ok, [input_record()]} | {:error, error()}
```

`error()` gains one arm, `:input_log_full` (decision 6), and
`@optional_callbacks` gains `supports_input_log?: 1, append_input: 3,
list_inputs: 2`.

`append_input/3` is handed an `input_record` whose `seq` the caller does not
know: **the adapter assigns it** and returns the assigned value, because
denseness is a property only the store can compute atomically. The `seq` key
on the argument is therefore ignored on the way in and authoritative on the
way out; `sp-80g` may spell the argument as an `input_record` without `seq`
rather than as one with an ignored field, which is the same decision either
way and a shape question, not a contract one.

`list_inputs/2` returns the run's whole log in ascending `seq` order, always -
no filter, no range, no limit, no reverse. The whole log is what a replay
consumes and the cap of decision 6 is what bounds it; a query surface would
be a second thing to specify and conform for no reader that exists. A run
with no inputs is `{:ok, []}`, and a run that does not exist is `{:error,
:run_not_found}`, the not-found arm this layer already requires instead of
`nil` or a raise.

Names, against a repository where `append_input`, `list_inputs`,
`input_log`, `supports_input_log?` and `Recording` currently have zero
occurrences in `lib/`: `input` rather than `event` because
`t:Statifier.Event.t/0` is a different thing from the row that carries it,
and this package already reserves `event` vocabulary for upstream's struct;
`log` rather than `history` or `trace` because "trace" is upstream's
`trace: true` message stream, which this is not.

### 3. An entry is the verbatim event, encoded above the adapter

An entry's payload is the `%Statifier.Event{}` the interpreter was handed,
verbatim: the same `name`, `type`, `data`, `cause`, `invokeid`, `origin`,
`origintype`, `sendid` and `caller_context` values, round-tripping to a
struct equal to the one that was delivered. `caller_context` and `origin`
ride on the event and are neither read nor rewritten here, exactly as
ADR-0009 decision 7 already has this package treat `caller_context`.

It crosses the adapter seam as an opaque `input_blob :: binary()`, encoded by
the facade above every adapter with `:erlang.term_to_binary/1` and decoded
with `:erlang.binary_to_term/1`, adopting `outcome_blob`'s established shape
(`driver.ex`'s `encode_outcome/1`) without variation. Two consequences of
that choice are the reasons for it: ADR-0003 decision 1 stays true word for
word - an adapter still sees binaries, strings and an ordinal, and never a
`Statifier` struct - and this package mints no serialization format, which
would be deviating from a contract it defers to (statifier-ex owns
serialization; this repository's CLAUDE.md names that deviation as the
failure to avoid).

**"The position it landed at" is the log's ordinal, and it is spelled `seq`.**
The word is already taken in this repository - a *position* is
`Statifier.Position.to_binary/1`'s output, the thing `position_blob` holds and
the identity guard guards - so the campaign-034 ruling's phrase is recorded
here under a name that cannot be confused with it. What a replay needs from an
entry is where it sat in the run's input order, which is an ordinal; what it
does not need is the configuration the run reached, which is derivable by
replaying the prefix and is rejected as a stored field in the Consequences
below. An entry therefore carries no position blob, and `seq` is dense from
zero so that a gap in a log is a defect rather than a reading.

The `door` and the `seq` are **outside** the blob, as their own columns: they
are structural, a reader sorts and filters on them, and a store that had to
decode every blob to order a log would be paying for the log twice.

### 4. The `input_blob` is a blob in ADR-0006's sense: `:blob_type` reaches it, and the door and the ordinal do not

An event's `data` is document payload. It can be, and in the two canonical
example domains routinely is, exactly the personal and cardholder data
ADR-0006 decision 2 keeps out of the `metadata` map: a signup's email
address, a capture's card number. The metadata map's "at rest in the clear"
posture is therefore wrong for this row, and it is the sharp case an
implementer will get wrong by pattern-matching on ADR-0006.

So `input_blob` joins `identity_blob`, `chart_blob` and `position_blob` as a
column `:blob_type` reaches, and the fourth entry in that list is the only
change this record makes to encryption. `run_id`, `seq` and `door` are
identity and lookup columns and never reach it, which is the same line
`ecto.ex` already draws.

**Note (2026-09-06, `sp-t12`):** the count above is wrong, and so is the
Context bullet it was taken from. `:blob_type` already reached *four*
columns when this record was written - `ecto.ex`'s `@blob_columns` carried
`outcome_blob` beside `identity_blob`, `chart_blob` and `position_blob`
before ADR-0010 - so `input_blob` is the fifth entry, not the fourth, and
the Context's "reaches exactly three columns" is short by one for the same
reason. Nothing decided here moves: `input_blob` is a `:blob_type` column
and `run_id`, `seq` and `door` are not, which is what `sp-80g` shipped.
ADR-0006's own list is corrected under `sp-a4x`, not here.

A host that cannot encrypt at rest and cannot accept plaintext payloads has
the decision-1 answer available to it: an adapter that does not export
`supports_input_log?/1` keeps no log at all.

### 5. Seven doors, one write site, and only inputs the interpreter saw

The door list is `t:StatifierPersistence.Runs.entry/0` - this record adds no
second door vocabulary and renames nothing.

| Door | Public entry points | Appends |
|---|---|---|
| `:step` | `Runs.step/5`, `Driver.send_event/4` | yes - the delivered event |
| `:done_invocation` | `Driver.done_invocation/5` | yes - the built `done.invoke.<invoke_id>` event |
| `:failed_invocation` | `Driver.failed_invocation/5` | yes - the built `error.communication.invoke.<invoke_id>` event |
| `:answer_parent` | `Driver.answer_parent/3` | yes - to the **parent's** log (decision 7), through the `done`/`failed` re-entry it performs |
| `:create` | `Runs.create/4`, `Driver.create/3`, `Driver.start_child_at/6` | no - `Interpreter.initialize/2` takes no event; a create opens the run's log empty |
| `:fail` | `Runs.fail/4` | no - a host decision about the record, no interpreter (ADR-0009 decision 3) |
| `:cancel` | `Runs.cancel/3`, `Runs.cascade_cancel/3` | no - same, and see the warning below |

`Runs.cancel/3` must not be mapped to upstream's `{:cancel, routes}`
recording entry. That entry means `Statifier.Interpreter.cancel/1` ran and
its exit walk executed `<onexit>` blocks; this package's `:cancel` changes a
record's status and touches no position. Mapping them would replay exit
actions the run never performed.

**One write site.** The append happens inside `Runs`' serialized unit, at the
single point where a resolved event is about to reach the interpreter -
never in `Driver`, which has no exclusion of its own. That is what makes the
log's order the run's order, and what makes `seq` assignment safe: the run's
exclusion is already held.

**Note (2026-09-06, `sp-t12`):** "about to reach the interpreter" is the
wrong side of the call, and `sp-80g` put the append on the right one: it
runs in `runs.ex`'s `stepped/6`, in the `{:ok, stepped_state, effects}`
branch of `Interpreter.handle_event/2`, so an event the interpreter
refused with `{:error, :not_running}` is never logged. That is the
paragraph below - "only inputs the interpreter saw" - and the two
sentences cannot both be satisfied on the same side of the call. Everything
the paragraph above is actually about holds unchanged: one write site,
inside the serialized unit, never in `Driver`, with the exclusion held when
the adapter assigns `seq`.

**Only inputs the interpreter saw are appended.** A delivery discarded before
the interpreter - a terminal run, an invocation the chart has since cancelled
(ADR-0007 decision 3), an event builder that declines - is *not* appended,
because a replay that applied it would produce a different run than the one
that happened. What was refused is already reported by
`[:statifier_persistence, :run, :discarded]`; this is a replay input log, not
an audit log, and decision 8 depends on that distinction holding.

**A failed append fails the step; the cap refusal does not.** The append is
part of the serialized unit, so an `{:adapter, term()}` from a backend that is
down fails the step the way any other write in that unit does - no
rescue-to-default at a leaf, this repository's first convention.
`{:error, :input_log_full}` is the sole exception: it is a boundary the host
declared on purpose (decision 6), the run continues, and the log records its
own truncation rather than the run recording a failure.

**`entry:` stops being telemetry-only.** `t:Runs.opt/0`'s `entry:` is
documented today as "telemetry-only: ... this option changes nothing but the
reported value". After `sp-80g` it also stamps the log's `door`, so that
sentence is false and updating it is part of that bead. The option stays what
it is otherwise: this package's own, never a host's.

### 6. The cap is declared at adapter init, and past it the log refuses and closes itself with a marker

An adapter's `init/1` opts carry `input_log_cap:` - a positive integer, or
`:infinity` for no cap. It is per run, it counts entries, and it is the
host's declaration at the place every other adapter-wide setting is declared.
It has no default this record fixes beyond `:infinity`; a bounded default
would be this package silently truncating a host's log.

Past the cap, `append_input/3` returns `{:error, :input_log_full}` and the
run's log is **closed**: the cap's last slot is written as a closed marker -
an `input_record` with `input_blob: nil` at the next `seq` - and no further
append to that run ever succeeds. The step itself succeeds and the run
carries on normally (decision 5).

The marker is the point. A truncated log that looks complete is worse than no
log, because `from_events/4`'s whole contract is that it fails closed
(`{:unknown_entry, entry}`, `{:initialize_opts, :trace_disabled}`, no partial
list) - and a log that silently lost its head satisfies every check it makes
while replaying a run that never happened. The marker makes the truncation a
value in the log, which decision 8's mapping refuses on.

Rejected: **drop-oldest**, the walk's other candidate. A ring buffer of
inputs is a correct design for an audit tail and the wrong one here, for two
independent reasons. A replay needs the *first* input most - the run's early
history is what the later inputs are meaningful against - so the entries a
ring drops are the ones that cannot be spared; and the surviving suffix is
indistinguishable from a complete log for a shorter run, which is the failure
mode the marker exists to prevent. A host that genuinely wants a bounded tail
of recent inputs is asking for a different facility and should say so.

### 7. One log per run, and a durable child's log is its own

A log belongs to exactly one `run_id`. A durable subchart's child is an
ordinary run (ADR-0008 decision 1), so it has its own log, holding its own
inputs, and nothing merges the two. No callback here takes a linkage, walks
one, or returns another run's entries.

The parent loses nothing by that. A child's answer reaches the parent through
`Driver.answer_parent/3`, which re-enters the parent through
`done_invocation`/`failed_invocation` - so the parent's log holds the answer
as an ordinary entry at the `:answer_parent` door, which is exactly the input
the parent's interpreter saw. What the parent's log does *not* hold is the
child's own inputs, and it should not: they were never the parent's inputs,
and replaying the parent does not replay the child.

A consumer that wants both narrations reads both logs and joins them on
`StatifierPersistence.Run.Linkage`, which ADR-0008 decision 2 already stores
and `[:statifier_persistence, :child, :started]` already carries. That is the
same shape `statifier-ui`'s `event_log` already assumes: one run draws one
stream.

### 8. The replay mapping is named here and built nowhere

This record fixes the mapping from a stored entry to a
`t:Statifier.Session.Recording.entry/0`; `from_events/4` is
`statifier-ui`'s and no code in this package calls it. Nothing in this
package gains a dependency on `statifier_ui`.

| Stored entry | `Recording.entry()` |
|---|---|
| door `"step"` | `{:event, event, nil}` |
| door `"done_invocation"` | `{:invoked_event, invoke_id, event, nil}` |
| door `"failed_invocation"` | `{:invoked_event, invoke_id, event, nil}` |
| door `"answer_parent"` | as the `done`/`failed` door it re-entered by |
| closed marker (decision 6) | none - the mapping refuses |

The `invoke_id` is not stored as its own field: it is derivable from the
event, whose name is `done.invoke.<invoke_id>` or
`error.communication.invoke.<invoke_id>` and whose `invokeid` field carries
it. `:invoked_event` rather than `:event` is what a live session records for
the same input (`session.ex`'s `Recording.put_invoked_event/4` on the
invocation-answer path, through the `enqueue_invoked/3` both its
`{:done_invocation, _, _}` and `{:failed_invocation, _, _}` casts share), and a
mapping that produced `{:event, ...}` would
replay an external delivery where the run had an invocation answer.

Two limits are stated rather than papered over:

- **The routes snapshot is `nil`.** Upstream's entries carry a
  `Statifier.Send.Routes.t() | nil`; this log stores none, so the mapping
  emits `nil`, which is the honest value only for a run driven without
  `routes:`. A run driven with a `routes:` snapshot replays with routing this
  record cannot promise is the routing it ran under.
- **The log is one of four replay inputs and supplies exactly one.** The
  chart is recoverable from this package's own chart store by
  `content_hash`; the entries are this log; the emission options are the
  reader's. The `initialize_opts` are **not** stored - `:trace`,
  `:datamodel`, `:max_macrostep_rounds`, `:routes`, `:invoke_types`,
  `:invoke_handlers` - and `:session_id` is recoverable only by decoding the
  position. A host that cannot reproduce the options its run was created
  under cannot replay it, log or no log.

Both are open questions with triggers, below. Neither blocks `sp-80g`, and
neither is fixed by guessing now: storing a routes snapshot per entry or an
options row per run are both additions this seam can take later without
changing anything decided above.

### 9. The Ecto adapter implements it on Postgres and SQLite, as migration V05

`StatifierPersistence.Storage.Ecto` exports all three callbacks and answers
`true`. The table is a fourth key in `t:StatifierPersistence.Ecto.KeyGenerator.table/0`
(`:charts | :positions | :runs` today), named through `Config.table/2`'s prefix and `:tables` override like
every other table (ADR-0002 decision 4, whose per-table override map is the
escape hatch) - no table name is hard-coded and none is a surrogate this
layer invents.

It ships as **V05** - `ecto/migrations/v05.ex`, beside `v01..v04`, reached by
the existing `up(for: ..., from: 5)` / `down(for: ..., version: 5)` spelling
and needing no change to `migrations.ex`'s contract. Columns: `run_id`,
`seq`, `door`, `input_blob`, with a unique index on `(run_id, seq)` and the
insert taking its `seq` from the run's current maximum under the exclusion
the append already runs inside. The unique index, not the read, is what makes
denseness true: a lost race fails the write rather than duplicating an
ordinal.

Both backends, on the same conformance suite. SQLite is not a lesser tier
here - `config/test.exs`'s `SqliteTestRepo` runs beside Postgres, and
`docs/non-postgres-backends.md` (sp-5lm) already writes down what is
Postgres-only and how a host declines it - and nothing in this design needs a
Postgres-only feature: there is no `jsonb` predicate, no advisory lock of its own, and no
index type beyond a unique one.

`StatifierPersistence.Testing.StorageConformance` gains the cases, and they
are the contract: an adapter that does not export the callbacks skips them
(the `function_exported?/3` shape the suite already uses for `isolate/1`);
append-then-list returns the entries in ascending `seq`; `seq` is dense from
zero; a `%Statifier.Event{}` round-trips equal, `caller_context` and all;
`list_inputs/2` on an unknown run is `{:error, :run_not_found}`; a cap of `n`
admits `n - 1` inputs and then a closed marker, and every later append is
`{:error, :input_log_full}` with the run still steppable; and two runs'
logs never see each other's entries.

**Note (2026-09-06, `sp-t12`):** two shapes this section left open have
answers now, and neither reopens the decision. First, the lost race: this
section says only that the unique index fails the write, and `sp-80g`
spelled that failure `{:adapter, :seq_conflict}`, the adapter-error arm
`Storage.Ecto` returns off the V05 `(run_id, seq)` constraint. Second,
"both backends, on the same conformance suite" is true of the cases and
not of the module: `StatifierPersistence.Testing.StorageConformance` gained
them and Postgres runs them through it, while the SQLite backend - which
runs no `StorageConformance` module in this repository, before ADR-0010 or
after - carries the same cases mirrored in
`test/statifier_persistence/ecto/sqlite_migrations_test.exs`, where every
other SQLite case already lives. SQLite is still not a lesser tier: append
and list, denseness from zero, run isolation, the cap and its marker, and
the verbatim event round-trip are all asserted against it.

## Consequences

- A persisted run becomes replayable for the first time. That is `sp-2sg`'s
  question answered and `se-dh0`'s Run-pane-over-replay unblocked, and it is
  the only reason this seam exists: nothing in this package reads the log.
- `Storage.Adapter` goes from fourteen callbacks to seventeen, and from six
  optional ones to nine. That is a real cost paid in a behaviour that hosts
  implement, and it is why decision 1 refuses at no door: an adapter author
  who ignores this record entirely is finished with it.
- The package stores document payload for the first time. Chart blobs,
  position blobs and identity blobs are engine-shaped; an event's `data` is
  the host's own values, and now it is at rest. Decision 4 puts it inside
  `:blob_type` and decision 6 lets a host bound how much of it accumulates,
  but the honest summary is that turning this log on is a data-retention
  decision a host makes, not a debugging switch it flips. the adapter's moduledoc
  and this package's README say so where a host will read it, which is
  `sp-80g`'s to write.

  **Note (2026-09-06, `sp-t12`):** two small things about that bullet. Its
  third sentence starts lowercase - read it as "The adapter's moduledoc";
  a word is a word, so it is corrected here rather than edited in place. And
  it is written: `sp-80g` put the retention paragraph under its own heading
  in `Storage.Adapter`'s moduledoc ("The input log is a data-retention
  decision, not a debugging switch") and in the README, both on `main` at
  `27a7a15`.
- A log costs one insert per step on the hottest path in the package, inside
  the exclusion. It is the only per-step write that grows without bound in
  the run's lifetime, which is what decision 6's cap is for.
- `sp-80g` is the code, in one shape it does not get to redesign: the
  callbacks of decision 2, the encode site of decision 3, the single write
  site and the door table of decision 5, the cap and the marker of decision
  6, the V05 migration and conformance cases of decision 9.
- Rejected alternative: **keeping the log in the host**, beside this package.
  It is where `sp-2sg` started, and it fails on ordering - a host outside the
  exclusion cannot know the order its own inputs were serialized in when two
  arrive at once, which is precisely the case a durable run exists to
  survive.
- Rejected alternative: **storing a position blob per entry**, so that any
  point in the run could be loaded directly rather than replayed. It stores
  the largest value this package holds once per step, and it answers a
  different question (what was the configuration then) than the one asked
  (what were the inputs), which replay answers from a log a fraction of the
  size.
- Open question, with its trigger: **the routes snapshot** (decision 8). The
  trigger to widen an entry by a stored snapshot is a host driving a durable
  run with a non-`nil` `routes:` and needing a faithful replay. A host that
  drives without one loses nothing today.
- Open question, with its trigger: **the create-time `initialize_opts`**
  (decision 8). The trigger is `se-dh0`, or any host, finding that it cannot
  reproduce the options its run was created under from what it already
  stores. The fix, if it fires, is a row written once at `:create` - not a
  change to the two callbacks decided here.
- What would reopen this record: either trigger firing; a consumer needing a
  bounded recent-inputs tail rather than a replayable log (decision 6's
  rejected alternative, which would be a second facility and not an amendment
  to this one); or upstream widening `t:Statifier.Session.Recording.entry/0`
  with a shape a door here can produce, which is an amendment to decision 8's
  table.
