### Added

- `send_types:` on `StatifierPersistence.Executions.create/4` and `step/5`, the `Statifier.Send.Types.t/0` snapshot of the host's registered Event I/O Processor types, stamped onto the loaded position the way `invoke_types:` is.
- `send_types:` on `StatifierPersistence.Driver.new/3`, a driver-level default carried onto every step and, through `initialize:`, onto the create.

### Changed

- The `statifier` floor is `~> 2.6`, the first release carrying host-registered send types.
