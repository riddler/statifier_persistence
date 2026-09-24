### Fixed

- A durable child's automatic answer to a parent whose record does not
  fetch, or whose chart the `chart_resolver:` does not return, reports
  `[:statifier_persistence, :child, :answered]` with `delivery:
  :parent_unfetched` or `:parent_chart_unresolved` instead of being dropped
  with nothing emitted.
