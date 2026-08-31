### Fixed

- `StatifierPersistence.Runs.create/4` passes only its `metadata:` pair to
  `StatifierPersistence.Storage.check_metadata/2`, whose contract is the
  narrower `[Storage.run_write_opt()]`. Handing the whole option list over
  made dialyzer derive a success typing for `create/4` that accepted no
  `executor:` at all, so an embedder had to suppress "will never return" on
  every correct call; that suppression can now be deleted.
