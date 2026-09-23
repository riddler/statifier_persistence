### Fixed

- `StatifierPersistence.PinSource.collect/3`, and `StatifierPersistence.Executions.retire_chart/4` through it, refuse a pin source that throws or exits - a `GenServer.call/3` timing out inside `pins/2` - under the reasons `{:thrown, value}` and `{:exited, reason}`, instead of letting the throw or exit escape the call; a host that matches `t:StatifierPersistence.PinSource.reason/0` exhaustively adds those two arms.
