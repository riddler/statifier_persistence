# The durable per-run input log Implementation Plan

**Status**: written 2026-09-06 against `origin/main` at `e815115`, the
commit that merged ADR-0010 (`sp-o1b`). Bead: `sp-80g`.

## Overview

Implement ADR-0010 as merged: the three optional storage-adapter callbacks
(`supports_input_log?/1`, `append_input/3`, `list_inputs/2`), the facade
that encodes a `%Statifier.Event{}` above every adapter, the one write
site inside `Runs`' serialized unit, the Ecto implementation on Postgres
and SQLite as migration V05, the host-declared cap with its closed
marker, and the conformance cases that are the contract.

The record is the specification. This plan does not re-decide anything in
it; where the bead's own paraphrase and the record disagree, the record
wins (the ordinal is `seq`, not "position").

## Current State Analysis

- `Storage.Adapter` (`lib/statifier_persistence/storage/adapter.ex`) has
  fourteen `@callback`s, six of them in `@optional_callbacks` (`:422`).
  None appends an event. `error()` (`:156`) has no `:input_log_full` arm.
- The optional-capability shape is settled: an adapter exports
  `supports_*?/1`, and the facade asks through `Code.ensure_loaded?/1` +
  `function_exported?/3` (`storage.ex:404`, `:453`).
- `Runs.step/5` (`runs.ex:357`) runs its tail inside `serialized/5`
  (`:625`), which holds the per-run exclusion. The resolved event reaches
  the interpreter in `stepped/6` (`:777`), after `resolve_event/2` has
  had its chance to decline.
- Every `Driver` door funnels into `Runs.step/5` or `Runs.create/4` and
  stamps its own `entry:` on the way (`driver.ex:1107`, `:723`), so
  `Driver` needs no write site of its own.
- `t:Runs.entry/0` (`runs.ex:226`) is the seven-atom door vocabulary,
  documented as telemetry-only (`:193`).
- The Ecto layer generates three schemas from `@fields`
  (`ecto.ex:59`) over three table keys (`config.ex:44`,
  `key_generator.ex:31`); `:blob_type` reaches `@blob_columns`
  (`ecto.ex:53`). Migrations run V01..V04 (`migrations.ex:98`).
- `StorageConformance` (`lib/statifier_persistence/testing/`) generates
  optional cases behind `function_exported?/3` at generation time
  (`:435`, `:497`, `:545`, `:717`).
- SQLite has one test module of its own
  (`test/statifier_persistence/ecto/sqlite_migrations_test.exs`), with
  its own repo, its own file database and no sandbox.

## Phases

### Phase 1 - the seam and its conformance cases

`adapter.ex`: the `seq`/`door`/`input_record` types, the three callbacks,
the `:input_log_full` error arm, the three additions to
`@optional_callbacks`, and the moduledoc's data-retention paragraph.

`storage.ex`: `input_log_supported?/1`, `append_input/4` (encoding the
event with `:erlang.term_to_binary/1`), `list_inputs/2` (decoding), and
the `t:input/0` read shape.

`StorageConformance`: the input-log cases, generated only when the
adapter exports the callbacks.

A test-support adapter (`test/support/input_log_adapter.ex`) implements
the log over an Agent so the cases run without a database.
`Storage.InMemory` is deliberately **not** changed: decision 1 names it
as the adapter that stays conformant without a line of change, and it is
the negative case the "skips them" contract needs.

Gate: full `mix quality`.

### Phase 2 - the Ecto adapter and V05

`key_generator.ex` (`:inputs` in `t:table/0`), `key_generator/uxid.ex`
(the `input` prefix), `config.ex` (`:inputs` in `@table_keys` and the
`:tables` docs), `ecto.ex` (the fourth schema module, its field list,
`:input_blob` in `@blob_columns`), `ecto/migrations/v05.ex` (the table
and its unique `(run_id, seq)` index), `migrations.ex`
(`@current_version 5` and the registry row), `storage/ecto.ex` (the three
callbacks and the `:input_log_cap` init option).

Tests: the migration up/down round trip on Postgres, the same on SQLite,
and the input-log conformance behaviours exercised against `Storage.Ecto`
on SQLite in that adapter's own module.

Gate: full `mix quality`.

### Phase 3 - the write site

`runs.ex`: the append inside `stepped/6`, after `Interpreter.handle_event/2`
has accepted the event and before the persist tail - "only inputs the
interpreter saw" (decision 5) rules out appending ahead of the call,
because `{:error, :not_running}` is a discard. `Runs.inputs/2` for the
read. The `entry:` option's doc stops saying "telemetry-only".

Tests: the door table end to end (create -> step -> done_invocation ->
answer_parent), the discards that append nothing, and the cap refusal
leaving the run steppable.

Gate: full `mix quality`.

### Phase 4 - docs and the fragment

README's adapter section, the `Storage.Ecto` moduledoc's option list, and
`changelog.d/sp-80g.md` (MINOR, 0.9.0).

Gate: full `mix quality`.

## Success Criteria

Automated:

- Conformance cases for append, ordered list, `seq` denseness, the
  verbatim event round trip, `:run_not_found`, per-run isolation and the
  cap-plus-marker pass against `Storage.Ecto` on Postgres, against the
  in-memory log adapter, and (as their mirror) against `Storage.Ecto` on
  SQLite.
- `Storage.InMemory`, which exports none of the three callbacks, passes
  the 0.8.0 suite unchanged and generates none of the new cases.
- A run driven create -> step -> done_invocation -> answer_parent lists
  exactly those inputs, in ascending `seq`, with their doors.
- V05 up and down round-trip on both backends.
- Full `mix quality` green.

Manual (deferred to a human):

- None identified; every criterion above is machine-checkable.

## Out of scope

- The replay mapping of decision 8: named in the record, built nowhere.
- Any wire-format change (campaign consent clause 6): the door and the
  ordinal live in the table and never in a trace message.
- Flipping ADR-0010 to accepted - that is `sp-t12`.
