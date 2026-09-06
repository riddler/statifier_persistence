### Added

- `StatifierPersistence.Runs.fail/4` takes a `driver:` option: a durable
  subchart child failed from outside the interpreter now answers its
  parent's `<invoke>` with the failure instead of leaving it pending
  forever (ADR-0008's note on the outside-fail seam).
- Adds `StatifierPersistence.Driver.resolve_and_answer_parent/3`, the
  public form of the automatic answer - resolve the parent's chart through
  `chart_resolver:`, then answer through `answer_parent/3` - for a caller
  that has no drive of the child to hang it off.
