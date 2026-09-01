### Added

- `StatifierPersistence.Driver.dispatch_context/0` carries `:invoke`, the whole
  `Statifier.Effect.Invoke` being dispatched, so a `:dispatch` fun can read the
  element's `src` - the document id a subchart handler resolves its child chart
  by - along with `content`, `autoforward`, and the step counters.
