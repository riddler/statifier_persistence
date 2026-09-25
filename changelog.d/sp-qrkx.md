### Added

- `selection` on `[:statifier_persistence, :execution, :step, :stop]`: `:selected` when the event the step delivered selected a transition, `:none` when it selected none, whether or not tracing is on, and `nil` on a stop that delivered no event (`:create`, `:fail`, `:cancel`) or returned no position.

### Changed

- Requires `statifier ~> 2.9`, whose `MachineState.last_selection` the new `selection` key is read from.
