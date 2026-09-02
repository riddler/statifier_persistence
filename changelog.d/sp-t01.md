### Added

- Durably-stepped runs now emit statifier's own `[:statifier, :session, ...]`
  telemetry with `driver: :persistence`, so `opentelemetry_statifier` produces
  the same macrostep spans and effect events for a durable run as for a
  session-hosted one, with no bridge change.
