### Added

- `StatifierPersistence.PinSource`, a behaviour a host implements so state this package cannot see - a pending timer, an address row - can report named counts against a content hash, with `collect/3` gathering each source's counts under its module name and turning a source that raises or answers malformed into `{:error, {module, reason}}` rather than a zero.
