### Added

- `[:statifier_persistence, :child, :answered]` carries `delivery`
  (`:delivered`, `:discarded`, `:needs_migration` or `:error`), so a durable
  child's automatic answer that a parked parent refused reaches the host
  instead of passing unnoticed.
