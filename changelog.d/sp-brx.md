### Added

- `StatifierPersistence.Executions.retire_chart/4` retires a chart, or refuses with every pin count when anything still uses it.
- `StatifierPersistence.Storage.retire_chart/3`, `chart_retirement_supported?/1` and `list_active_execution_ids_by_content_hash/2` over three new optional adapter callbacks, `retire_chart/3`, `supports_chart_retirement?/1` and `list_active_execution_ids_by_content_hash/2`.
- A position row on a content hash is a pin: it refuses a retirement of that chart even when no execution runs on it.
- The generated chart schema carries the `retired_at` and `retired_by` columns migration V07 adds.

### Changed

- `StatifierPersistence.Storage.fetch_chart/2` gains a `{:chart_retired, info}` error arm for a retired hash, carrying who retired it and when, instead of `:chart_not_found`.
- `StatifierPersistence.Storage.save_chart/3` refuses that same arm for a retired hash rather than reviving the row.
- The adapter error vocabulary gains `:chart_retirement_unsupported`, the refusal for a store whose chart blob columns are not nullable, and `{:pinned, counts}`, the refusal carrying every count.
