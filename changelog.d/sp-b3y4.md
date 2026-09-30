### Changed

- `StatifierPersistence.Testing.StorageConformance` defines every attribute, function and nested module it puts into a host test module under one reserved prefix, `conformance_` (`Conformance` for a nested module), and its moduledoc states that prefix as the host contract, so a host module's own helpers no longer collide with the suite's; a host test module that called one of the suite's helpers by its old name (`input_log_execution/2`, for one) adds the prefix, and the telemetry handler `__conformance_forward_adapter_call__/4` is now `conformance_forward_adapter_call/4`.
