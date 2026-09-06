# ADR-0005: The Ecto layer ships in this package; the test harness is real Postgres

Status: accepted (2026-08-22)

## Context

The Ecto adapter epic (sp-4an.3) opens on two questions its charter left
deliberately unanswered until the work started. `mix.exs` recorded the
first verbatim: does the Ecto layer live in this package behind an
optional dependency, or in a separate `statifier_ecto` package? The second
is what the epic's database-backed tests run against: a real Postgres
server, an embedded stand-in (SQLite), or an in-memory fake.

The surrounding records constrain both answers. ADR-0002 decision 3 names
`use StatifierPersistence.Ecto` - this package's namespace - as where a
host configures keys and tables, and makes the versioned migrations helper
"the only supported way to create or upgrade the tables". ADR-0003
decision 5 ships the conformance suite in this package's `lib/` precisely
so a downstream adapter can `use` it; ADR-0004's Consequences hand the
Ecto adapter three run callbacks and an optional `lock_run/3` to implement
as a transaction-scoped row lock (`SELECT ... FOR UPDATE`). Ecto already
has the pattern for a library that is optional to compile against:
`Code.ensure_loaded?/1` guards around the modules that reference it, and
the host brings its own database driver.

On the harness side, the repository's own gate rules bind harder than
convenience: "never go green by weakening the check", explicitly including
`@tag :skip` on tests that cannot run. A database suite that silently
skips when no server is reachable is exactly that weakening - the gate
reports green while the adapter is untested.

## Decision

**1. The Ecto layer lives in this package, behind optional `ecto_sql`.**
No separate `statifier_ecto` package: it would split one contract
(behaviour + conformance suite here, the adapter that must pass them
there) across two repos, duplicate the test surface, and contradict
ADR-0002's already-accepted `use StatifierPersistence.Ecto` spelling, all
for no consumer benefit. Concretely:

- `{:ecto_sql, "~> 3.10", optional: true}` - a host that only wants the
  behaviour, the in-memory adapter, or the stepper loop compiles this
  package without Ecto anywhere in its tree.
- Every module that references Ecto is wrapped in
  `if Code.ensure_loaded?(Ecto)` so the package compiles clean either way.
- `{:uxid, "~> 2.0"}` is a required dependency: ADR-0002 decision 2 makes
  `:uxid` the default key scheme and the default must work out of the box.
- `{:postgrex, "~> 0.19", only: :test}` - a host brings its own database
  driver; this package needs one only to test itself.

**2. The test harness is a real Postgres server with the SQL sandbox.**
Database-backed tests are ordinary tests in the ordinary suite, isolated
per test through `Ecto.Adapters.SQL.Sandbox` (the checkout the
conformance suite's optional `isolate/1` callback already anticipates).
The server comes from `docker compose up -d db` locally (postgres:17,
credentials and port overridable via `PG*` env vars) and a `postgres:17`
service container in CI. Rejected alternatives:

- SQLite or any embedded stand-in: `lock_run/3` is specified as a
  transaction-scoped row lock, and `SELECT ... FOR UPDATE` semantics are
  exactly what an embedded engine fakes differently or not at all. A
  migration suite proven against a database no host will run proves
  little.

  **Note, 2026-09-06 (campaign-033, `sp-kka`):** "a database no host will
  run" has been overtaken by events and should be read as scoped to the
  *harness* question this decision answers, not as a claim about hosts.
  `statifier_examples`, this family's reference embedder, runs SQLite by
  default (`{:ecto_sqlite3, "~> 0.22"}` in its `mix.exs`), and the shipped
  conformance suite passes 25 of 27 cases against it - only the `lock_run/3`
  pair fails, on `hashtextextended` (`sp-5lm`, from `se-cnv`). What that
  evidence supports is the sentence before it, which stands unchanged: an
  embedded engine does not give `SELECT ... FOR UPDATE` the semantics
  `lock_run/3` is specified against, so this repository's own gate keeps its
  real-Postgres harness and decision 2 is not reopened. What it does not
  support is the rejected alternative's wider aside about who runs SQLite.
  The gap between "hosts do run it" and "the lock callback cannot be honored
  there" is what `sp-msr` documents: a first-class decline-the-callback
  opt-out plus the conformance suite tagging the lock pair Postgres-only
  (fleet ruling RQ-033-8, 2026-09-06). This Note adds a scope; it removes
  nothing and changes no decision.

- An in-memory fake: the conformance suite exists to test adapters
  against real backends; running it against a fake of the backend is
  circular.
- A skip tag for when the server is absent: an auto-skipped database
  suite is the gate weakening this repository's rules forbid. Absent
  server, red suite, loudly.

## Consequences

- From this record on, every `mix quality` run in this repository
  requires a reachable Postgres server, by design. `docker compose up -d
  db` is now part of standing up a working checkout, and the README says
  so. A run without the server fails loudly in the connectivity smoke
  test rather than skipping quietly.
- CI carries a Postgres service container from here forward; its
  credentials and the local compose defaults are the same values, so the
  `PG*` env vars are an override mechanism, not a setup step.
- Hosts compiling without `ecto_sql` get no Ecto modules and no
  migrations helper - the `Code.ensure_loaded?` guard is the seam, and a
  missing-guard compile failure in such a host is a bug in this package.
- `uxid` becomes a transitive dependency of every host, ecto or not.
- What would reopen this record: a host that cannot take `uxid`
  transitively (decision 1's required-dependency clause); a second
  database the adapter must support (decision 2's Postgres-only harness);
  or the optional-dependency seam failing in practice - a host without
  `ecto_sql` that this package will not compile for.
