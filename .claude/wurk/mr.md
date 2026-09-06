# Statifier_persistence extension: /wurk:mr

Project facts and one rule that constrains a generic step. See
`~/.claude/skills/wurk:mr/SKILL.md` for everything this does not repeat.

## bd dolt push is the conductor's inside a cross-repo campaign

The generic skill's `bd dolt push` step is **not run** when this repo is
being worked as part of a cross-repo campaign over the statifier family. The
authority table in `CLAUDE.md` already records why: the campaign's conductor
pushes the mirrored trackers atomically, and a per-repo push from inside one
repo's pipeline can interleave with pushes to the paired trackers and leave
`mirrors:` halves pointing at states the other side has not seen.

So: inside a campaign, record the request URL on the bead with `bd note` /
`bd update` locally and leave the dolt push to the conductor. Outside a
campaign, `bd dolt push` is the operator's call, as the table says - ask,
do not assume.

## Push and request authority: consent-scoped

Pushing the branch and opening the request are gated by the same authority
table this repo's `CLAUDE.md` carries: they happen only inside a campaign
carrying the operator's explicit, quotable consent, and only after the
terminology scan below is clean.

Merging the request is the operator's, with the one exception that table's
own *merging a campaign PR* row records (added 2026-09-01, after the 025
post-wrap walk): a campaign consent the operator adopted verbatim that names
automatic merges, with every condition the row lists met - full gate green,
CI green, the terminology scan clean with a positive control, and any named
review gate passed. Read the row for those conditions rather than this
paragraph; the row is the authority and this is the pointer at it. Outside
such a consent, with any one of the row's conditions unmet, or for a request
the consent's own carve-outs hold for the operator: open it and stop.

This skill never closes the bead, and in this repo a mirrored bead is never
closed by an agent regardless.

## The terminology firewall gates the push

Before the push and before opening the request, run the scan from the
umbrella's `docs/terminology-firewall.md` over the full outbound content:
the diff, every commit message on the branch, and the request title and body.
Any hit is a hard stop - report the offending strings; do not rephrase and
retry on your own.

## The request is a record, not a review gate

One contributor. The repo runs a "Full quality gate" CI workflow on each
request, but the local full `mix quality` before the push remains the
required verification - CI is a second check on the request, not a
substitute - so treat a skipped or scoped local gate on a branch that
touches gated paths as a hard stop, not a formality to catch up on later. (A branch touching no gated
paths has no gate to run; say so in the request body.) What the request is
for is the record: a diff with a written rationale, linked to its bead, that
can be read later.

## Cite branches and requests, not SHAs

Merges here land non-fast-forward, so a pre-merge commit SHA written into a
bead note or request body is orphaned the moment the request merges. When the
request text or bead notes need to point at this work later, name the branch
and the request number, not a SHA.
