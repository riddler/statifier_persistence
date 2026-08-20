# ADR-0001: Record architecture decisions

Status: accepted (2026-08-20)

## Context

This package sits on contracts owned elsewhere - statifier-ex's interpreter
and serialization records (st-ADR-0052, st-ADR-0060) bind what an adapter
may do - while owning contracts of its own that hosts build against:
storage/locking semantics, the run lifecycle, and the Ecto adapter's
schema. Decisions in that second group change what hosts read and what
migrations they have already run; unrecorded, they become folklore or
silent breakage.

The sibling repos record decisions as ADRs under `docs/adr/`: numbered
sequentially, three sections (Context, Decision, Consequences), indexed in
`docs/adr/README.md`. Citing a number ends re-argument; amending is
explicit. Cross-repo citations carry the owning repo's beads prefix
(`st-ADR-0052`); a bare `ADR-NNNN` is always this repository's own
(umbrella decision D8).

## Decision

This repository records architecture decisions the same way. A decision
owned by another repository is adopted by reference, never restated in a
way that could drift. The bar for writing one: the decision changes what a
host reads - the behaviour's contract surface, schema/migration shape,
locking semantics, dependency shape.

## Consequences

- Decisions land as ADRs before or with the code that encodes them.
- Contract authority follows the umbrella rule: storage, locking, and
  stepping are decided here; interpreter, effect vocabulary, chart
  identity, and serialization are statifier-ex's and this repo defers.
- No automated ADR tooling is adopted yet; that is a decision to record
  when there is an ADR set worth protecting mechanically.
