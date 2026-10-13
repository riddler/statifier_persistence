### Added

- `function_providers:` on `StatifierPersistence.Executions.step/5`, inside `initialize:` on `create/4`, and on `StatifierPersistence.Driver.new/3` as a driver-level default each call may override: the host's guard functions are stamped onto the loaded position beside `routes:`, `invoke_types:` and `send_types:`, so a resumed execution evaluates a `cond` or `expr` that calls one without the host touching `Statifier.MachineState`. A durable subchart child the driver creates does not inherit the list.
- When `function_providers:` is passed, a list that does not resolve is refused at the entry with `{:error, {:function_providers, reason}}`, before any lock, load or write, on `step/5`, `create/4` and the driver's `create/3`, `send_event/4`, `done_invocation/5`, `failed_invocation/5` and `answer_parent/3`; `t:StatifierPersistence.Executions.error/0` gains the arm.

### Changed

- The `statifier` requirement moves from `~> 2.9` to `~> 2.15`, the first release carrying host function providers; a host on statifier 2.9 to 2.14 moves statifier with it.
