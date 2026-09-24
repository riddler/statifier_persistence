### Fixed

- `StatifierPersistence.Executions.migrate/4` and `migrate_tree/4` refuse,
  with `{:invocation_element_changed, key, target}`, a stored active
  invocation whose ordinal names no `<invoke>` element of its state when the
  plan keeps it at that ordinal, instead of carrying it onto whatever element
  the new chart holds there. Repair the stored position.
