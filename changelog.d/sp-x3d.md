### Added

- Two optional `StatifierPersistence.Storage.Adapter` callbacks, `supports_retired_info?/1` and `fetch_retired_info/2`: an adapter that exports both answers whether a content hash is retired without reading the chart's bytes. `StatifierPersistence.Storage.Ecto` and `StatifierPersistence.Storage.InMemory` implement them; an adapter that does not export them stays conformant and is read through `fetch_chart/2` as before, and the conformance suite checks whichever path the adapter declares.

### Changed

- **Breaking** for a host whose telemetry handler matches the `callback` of `[:statifier_persistence, :adapter, :call]` exhaustively: `StatifierPersistence.Storage.check_chart_retired/2`, and `StatifierPersistence.Executions.create/4` through it, report `:supports_retired_info?` and `:fetch_retired_info` in place of `:fetch_chart` on an adapter that declares the narrow read, as both bundled adapters do. A handler with no clause for the two new names raises, and `:telemetry` detaches it; add them, or a catch-all.
- `StatifierPersistence.Executions.create/4`'s check for a retired chart no longer transfers the chart's stored bytes on an adapter that declares the narrow read, so its cost stays flat as charts grow; the `[:statifier_persistence, :adapter, :call]` event for that check names `:supports_retired_info?` and `:fetch_retired_info` instead of `:fetch_chart` on such an adapter.
