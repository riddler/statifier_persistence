### Fixed

- `StatifierPersistence.Testing.StorageConformance` no longer registers a
  `setup` that writes: the input-log cases build their fixture run inside
  the case body, so a host's own `setup` - even one written below the
  `use` - is no longer preceded by a write. The moduledoc states the
  ordering contract a host binds against.
