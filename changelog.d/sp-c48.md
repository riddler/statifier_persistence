### Added

- `StatifierPersistence.Driver.new/3` takes `after_step:`, a
  `(run_id, machine_state, effects -> any)` callback fired after every step
  the driver takes on a caller's behalf - a durable subchart child's own
  steps and the parent's step on the answer path included, each under the id
  of the run that was stepped, with the whole effect list that step produced.
  It defaults to `nil` and may be overridden per call on `create/3`,
  `send_event/4`, `done_invocation/5` and `failed_invocation/5`.
