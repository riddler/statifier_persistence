### Added

- `StatifierPersistence.Executions.executions_on/2` counts the executions on one content hash, per stored status.
- `StatifierPersistence.Storage.count_executions_by_content_hash/2` and `content_hash_query_supported?/1` over two new optional adapter callbacks, `count_executions_by_content_hash/2` and `supports_content_hash_query?/1`.
- Migration V07: an index on `executions(content_hash)`, the nullable `retired_at` and `retired_by` columns on `charts`, and - on Postgres - nullable `identity_blob` and `chart_blob` on `charts`.

### Changed

- The adapter error vocabulary gains `:content_hash_query_unsupported`, the refusal for an adapter that cannot answer the content-hash count.
