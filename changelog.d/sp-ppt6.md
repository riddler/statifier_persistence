### Added

- `StatifierPersistence.Executions.inherited_metadata/3` answers `{:ok, map}` holding each named host metadata key an execution's stored record holds, with its value, so a host reads the keys a durable subchart child copied under `inherited_metadata_keys:` without walking the linkage; a record that cannot be read answers the read's error, and naming the reserved linkage key raises `ArgumentError`.
