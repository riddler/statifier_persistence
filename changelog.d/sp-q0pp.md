### Changed

- **Breaking** for a host whose telemetry handler matches `delivery` on
  `[:statifier_persistence, :child, :answered]` exhaustively: `delivery`
  has two new values, `:parent_unfetched` and `:parent_chart_unresolved`,
  and on them `outcome` is the child's own and `failed_count` is `nil`, even
  for a fan-out. Add clauses for the two values or a catch-all.

### Fixed

- A durable child's automatic answer to a parent whose record does not
  fetch, or whose chart the `chart_resolver:` does not return, reports
  `[:statifier_persistence, :child, :answered]` with `delivery:
  :parent_unfetched` or `:parent_chart_unresolved` instead of being dropped
  with nothing emitted.
