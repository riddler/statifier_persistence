# Statifier_persistence extension: /wurk:commit

Additional required steps and project facts. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Authority: consent-scoped, and the gate is the whole check

The trigger for `git commit` is the authority table in this repo's
`CLAUDE.md`, which this file points at and does not restate: a campaign
carrying the operator's explicit consent, the bead's work complete, and full
`mix quality` green. That section is operator-adopted; nothing here widens or
narrows it.

Two consequences worth spelling out at commit time:

- **There is no CI and no second reviewer.** The full gate run before the
  commit is the only thing that ever verifies this branch. A
  `--profile loop` green is not the trigger - it skips dialyzer, deps audit,
  and coverage.
- **A diff touching no Elixir code has no gate to run** and may commit on
  review of the diff alone (the authority table says so explicitly). The
  manifest's `gate.build_paths` is the boundary: a docs-only or
  `.claude/`-only change falls outside it. Say in the commit body review that
  this is why the gate did not apply, rather than leaving it ambiguous.

## Sabotage discipline (the project's answer to `data.sabotage.missing`)

`data.sabotage.missing` is a report, not a gate, per the generic skill - but
this project's convention (CLAUDE.md: sabotage every new test that asserts
`lib/` behavior) makes it a real refusal condition:

- A test with no `# sabotage:` note directly above it has been *observed*
  passing, not *verified*. Break the `lib/` code it covers, confirm it goes
  red for the right reason, revert, confirm green, then write the one-line
  note above the test. Re-run the gate afterward.
- Never invent a note for a mutation that was not run - a fabricated note is
  the one failure mode this check cannot catch afterward. Refuse and report
  which tests are unverified instead.
- There are no exempt test roots here (`gate.sabotage.exempt_prefixes` is
  empty); every `lib/`-asserting test carries a note.

## Changelog: fragments, judged by changelog.d/README.md

`changelog.mode` is `fragments` with `dir: changelog.d`. The needs/no-entry
test is written down in `changelog.d/README.md` - one file per bead, named
`changelog.d/<bead-id>.md`, standard Keep a Changelog headings, entries only
for changes visible to someone calling the public API. While the package is
pre-first-release, most scaffold and tooling work needs no fragment, and that
is the expected outcome, not a step you skipped.

## Version bump: never

`mix.exs` holds the last released version until a release bead says
otherwise. `CLAUDE.md`'s authority table is the authority on when that
happens and this section does not restate it: a release (tag,
`mix hex.publish`, GitHub release) is never an agent's, and the version-bump
row allows the bump only on an operator-authorized release bead's branch,
inside a campaign carrying the operator's explicit consent. Read the row
rather than a version quoted here, which goes stale at every release. Never
edit the version field as part of an ordinary commit.

## Gate thresholds are the operator's call

`gate.moving_files` lists `.quality.exs` and `coveralls.json`. A diff that
moves a number in either needs the operator to have asked for it - "the gate
went red and the threshold looked too strict" is the signal working, not a
reason to move it. Report the finding and stop. `.quality.exs` carries its
reasoning in comments; a change that moves a value without moving its reason
is incomplete regardless of who asked.

## Gate attestation: dep-provided mix quality.verify

The manifest wires `gate.attest` to `mix quality.verify`. The task ships with
`ex_quality` (`~> 0.14`, dev-only), so this repo carries no local copy of it,
on purpose, per the upstream ruling on st-hcgl. It adds no gate stage and does
not touch `.quality.exs`; it runs the gate with a machine-readable report and
attests only a full run (status ok, scope all, no profile, no run-narrowing
skip). An `--auto` run that reports `attested: false` is the check working -
report it, do not fake an attestation.

The earlier wiring named `mix gate.verify` (bead `sp-7cu`), which no dep ever
shipped; it was dropped entirely in f76db7d (`sp-cs0`, fleet ruling F2
2026-08-27) because the dangling declaration could yield a blocked
`gate_attest_could_not_start` envelope. Re-pointing it at the published
`ex_quality` task is what that commit deferred.
