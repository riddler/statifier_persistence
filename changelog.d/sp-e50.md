### Added

- `StatifierPersistence.Driver`'s `:dispatch` fun may answer `:pending`: the
  call was started asynchronously and the run rests durably with the
  invocation live, holding no process (ADR-0007).
- `StatifierPersistence.Driver.done_invocation/5` and
  `StatifierPersistence.Driver.failed_invocation/5` answer a pending
  invocation later, from any process or node, building the same
  `done.invoke` / `error.communication.invoke` events a live
  `Statifier.Session` builds. An answer for an invocation the chart has
  cancelled is `{:discarded, run}`, decided from the persisted position
  inside the run's serialization strategy.
- `StatifierPersistence.Runs.step/5` accepts an event builder - a fun over
  the loaded position returning `{:ok, event}` or `:discard` - anywhere it
  accepts a `Statifier.Event`.

### Changed

- The context handed to a `:dispatch` fun carries `invoke_id`, the
  invocation id an asynchronous host keys its work by and hands back to the
  re-entry doors.
