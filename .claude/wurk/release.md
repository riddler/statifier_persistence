# Statifier_persistence extension: /wurk:release

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others.

The reference for the shape is `957c122`, the 0.5.0 prep - the most recent
release prep in this repo, and the commit every step below is modeled on.

`changelog.d/README.md`'s "At release" paragraph is the checked-in statement of
the same procedure, written for the person dropping fragments rather than for
this skill. Where the two overlap they say the same thing, deliberately: the
fragments are assembled into a new version section grouped by heading and
ordered `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`; the
README's install-snippet pin moves to the new release line, it being "the one
user-facing version string outside `mix.exs`" (operator ruling, 2026-09-01);
and the fragments are deleted in the same commit that cuts the release. That
README's clause "and tag it" is the one place the two documents part, and only
because they address different readers - see the last section here.

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
unreleased work lives one file per issue in `changelog.d/`, and the fragments
are assembled into a version section at release. Pointing `release.changelog`
at `CHANGELOG.md` would make the skill's precondition read for an unreleased
section that is not there, and its edit rename a heading that does not exist.

So `release.changelog` is deliberately absent, and a recipe that does not name
a changelog names no changelog edit. The promotion this repo actually performs
is step B below - a required step, not an optional one. A release commit
without it is not a release commit.

The unreleased-work check the skill makes before anything else reads
`changelog.d/` here: if the directory holds no fragment other than its own
`README.md`, there is nothing to release, and the run stops exactly as it
would on an empty unreleased section. That is the directory's normal resting
state between releases, so a run that stops there has found the expected
condition, not a broken repo.

## Step A: the version carrier

**None.** `mix.exs`'s `@version` is the only place this package's version
string lives; `lib/` and `docs/` carry no second copy, and `mix.exs` derives
`source_ref: "v#{@version}"` from the same attribute rather than repeating it.
The skill's own `version_file` edit is the whole of the bump.

Stated explicitly so that a future release does not go looking for a carrier
that was never there. If one is ever added, it belongs in this section and in
the table below, in the same change that adds it.

`CLAUDE.md`'s "The package is released (0.5.x on Hex)" line is **not** a
carrier and does not move here. It states what is published, which stays true
until the operator publishes; `957c122`'s commit body says so in those words.
It moves in its own commit after a publish, never in the prep.

## Step B: promote the changelog fragments

Placed where the skill's changelog step would have been, and modeled on the
0.5.0 prep commit `957c122`, which is the reference for the shape.

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   above the previous version's section, dated today. The heading form is the
   one the file already uses throughout - the bracketed version, a single
   space, then the date, **with no `-` separator between them**. (Keep a
   Changelog's own form has the dash; this file has never used it in eight
   released sections, and a release is not the place to change them.)
3. Write a short lead paragraph between the heading and the first `### `
   sub-heading, saying what the release is. Unlike some sibling repos this one
   carries a lead on **every** section, `0.1.0` through `0.5.0`, so it is the
   rule here rather than the exception - one or two sentences naming the kind
   of release ("Feature release: ...", "Docs release: ...", "Patch release:
   ...") and what a user gets. A breaking change is called out in bold here
   too, as `0.4.0` does.
4. Under the lead, write the fragments' bullets grouped by heading and ordered
   `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
   **Carry every bullet over byte for byte.** The lead paragraph is the only
   prose written at release time; reordering, consolidating or rewording a
   fragment's bullet is an editorial pass a human does separately, before the
   release.
5. **No link reference.** Unlike sibling repos, this `CHANGELOG.md` has no
   link-reference block at the end of the file and no `[X.Y.Z]:` definitions
   anywhere - the bracketed versions in the headings are deliberately
   unlinked. Do not add one for the new version, and do not "repair" the file
   by adding the whole block.
6. Delete the promoted fragment files in the same commit. `README.md` stays.

Whether the release is major, minor or patch is not decided here - the version
is explicit input to the skill. The fragments' headings are evidence for that
judgement, not a rule that computes it, and the reasoning belongs in the
commit body, where `957c122` put it.

## The README install pin

`release.readme_pin` is `true`. `README.md`'s `def deps` snippet carries
`{:statifier_persistence, "~> X.Y"}` - the major/minor form with the patch
component dropped that the skill's step 2 bumps. `957c122` is the format
precedent as well as the shape precedent: it moved the pin from `~> 0.4` to
`~> 0.5` in the same commit as the bump.

`changelog.d/README.md`'s "At release" paragraph names this move as part of the
same step, on an operator ruling of 2026-09-01, so a prep that bumps `mix.exs`
and leaves the pin behind has skipped a step two documents ask for.

The optional `{:ecto_sql, "~> 3.10"}` line in the same snippet is a dependency
constraint, not this package's pin. It does not move at release.

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step B |
| `changelog.d/*.md` (deleted) | step B |

No `lib/` file appears in that table, and step A explains why. Neither does
`CLAUDE.md`, for the reason step A gives.

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. In this repo those are the operator's, in every campaign and
outside every campaign. `CLAUDE.md`'s authority table is explicit on both
halves:

- *a release (tag, `mix hex.publish`, GitHub release)* - trigger **never**,
  still unauthorized **always**: "publishing is the operator's, in every
  campaign".
- *a version bump on a release bead's branch* - allowed only on "an
  operator-authorized release bead, inside a campaign carrying the operator's
  explicit consent", and still unauthorized "on any other bead, on main, or
  when the operator has not named this repo's release bead".

So the one thing this recipe performs - the bump plus the step B promotion, on
a named release bead's branch, under a campaign consent that names it - is
release *prep*. `.claude/wurk/commit.md`'s "Version bump: never" section
records the same boundary from the commit side: the version field moves only
through a release bead, never as a convenience.

This is also the one place this file and `changelog.d/README.md` differ.
That README ends its "At release" paragraph with "and tag it", which is
correct for its reader - the operator, who does tag. It is not an instruction
this skill or any agent may carry out.
