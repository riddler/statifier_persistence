# ADR-0018: The release workflow publishes to Hex on a version tag, and only when the tagged commit is on the default branch, names the version in `mix.exs` and passes the full gate there

Status: proposed (2026-10-04)

## Context

A release of this package has three steps after its prep is merged: the
version bump and the changelog promotion land through the release recipe
(`.claude/wurk/release.md`), the merged prep commit is tagged with the new
version, and the version is published to Hex. `CLAUDE.md`'s authority
table already lets the conductor or the session that owns the release bead
make the first two (the version-bump and tagging rows, and the "Release
preps" paragraph). The third was a person's step, run by hand from a
checkout with a Hex key on that machine.

A hand publish asks a person to check by eye what a machine can check
exactly: that the commit being published is the one the default branch
carries, that the tag names the version the package states, and that the
full gate is green on that commit. It also needs a key on whichever
machine runs it.

The family's CI already runs the full gate on every push to the default
branch and every pull request (`.github/workflows/ci.yml`, job `gate`), with
the toolchain read out of `mise.toml` and the gate command read out of
`.claude/wurk.json` `gate.full`. Nothing runs on a tag push today.

## Decision

1. **A workflow publishes, on a version tag push and nothing else.**
   `.github/workflows/release.yml` triggers on `push` of tags matching
   `v*.*.*` only: no branch push, no pull request, no `workflow_dispatch`.
   Its token is read-only (`permissions: contents: read`). It runs one job,
   in a `concurrency` group keyed by the tag that never cancels a run in
   progress. The move from a hand publish to a tag-push publish was ruled
   by the operator, 2026-10-04.

2. **Three conditions hold at the tagged commit, or nothing is published.**
   Each is a step that stops the job before the next runs:
   - the tagged commit is an ancestor of the default branch's head
     (`git merge-base --is-ancestor`, step "Check the tagged commit is on
     the default branch"); the branch name is read from the push event
     (`github.event.repository.default_branch`), never written in the file;
   - the tag name without its leading `v` equals `@version` in `mix.exs` at
     the tagged commit (step "Check the tag names the version in mix.exs");
   - the full quality gate is green at the tagged commit (step "Full
     quality gate"), run as `ci.yml` runs it: the same Postgres service and
     `PG*` environment (ADR-0005), the same toolchain, cache and dependency
     steps, and the command from `.claude/wurk.json` `gate.full`.
   The ancestry and version checks run before the toolchain is installed. A
   fourth check runs with them: a version Hex already shows is reported and
   not published again (step "Check Hex does not already show this
   version"). That the workflow runs the gate itself rather than reading
   CI's result, that the branch comes from the event payload, that the
   version is read from `mix.exs` at the tag, and that the toolchain steps
   are copied from `ci.yml` rather than shared were decided by the
   conductor under a standing consent, 2026-10-03.

3. **The registry is Hex, and the key is the `HEX_API_KEY` secret.** The
   publish step runs `mix hex.publish --yes` with `HEX_API_KEY` taken from
   the `HEX_API_KEY` secret (an organisation secret the maintainers set up
   and rotate outside this repository) in that one step's `env:` and
   nowhere else (step "Publish to Hex"). No key is held by an agent or kept
   in the repository. The last step prints the published version's Hex and
   HexDocs addresses.

4. **The docs publish with the package.** `mix hex.publish` builds and
   publishes the docs by default, and the workflow keeps that default; the
   package-only form is not used. Decided by the conductor under a standing
   consent, 2026-10-04.

5. **A failed run is never retried by the workflow.** A run that stops at
   a check or at the gate publishes nothing, and the tag stands: the fix
   lands on the default branch and the next version is tagged; a tag is
   never moved. A run whose publish step failed on a registry or network
   error is re-run once by hand from its page in the Actions tab; a failed
   gate is never re-run, and a second failure of the publish step is the
   maintainers'. A publish that lands the package on Hex but fails on its
   docs leaves the version without docs; a re-run stops at the Hex check,
   and the docs are the maintainers'. A failed workflow is never worked
   round by a local publish. Decided by the conductor under a standing
   consent, 2026-10-04.

6. **A published version stands.** Hex lets a published version of an
   existing package be replaced or reverted only within one hour of its
   publication; after that it can only be retired. The workflow does
   none of these, and an agent never runs any of them.

## Consequences

- `CLAUDE.md`'s release row and "Release preps" paragraph, and the release
  recipe's publish sentence (`.claude/wurk/release.md`, "What a release
  here still is not"), now say that an agent or a session never runs
  `mix hex.publish`, that the release workflow publishes on the tag push the
  tagging row already allows, and that a failed workflow is re-run from its
  Actions page. The tag push is now the step that leads to a publish.
- Each release runs the full gate once more, on the runner, against the
  tagged commit. A release is slower by that run and cannot publish a
  commit the gate has not passed there.
- A tag whose commit is not on the default branch, or whose name differs
  from `@version`, publishes nothing and costs seconds. A re-run after a
  successful publish stops at the Hex check, and so ends red with nothing
  published.
- Hex prints warnings during a publish that nobody watches as it happens;
  they are in the run's log.
- The toolchain, cache, dependency and gate steps are a copy of `ci.yml`'s.
  A change to one is made to both in the same change.
