### Added

- When a driver's `function_providers:` list does not resolve, `StatifierPersistence.Driver.start_child_at/6` refuses with `{:refused, {:function_providers, reason}}`, its existing refusal shape, before any child is created or anything is written; a driver with a list that resolves, or with none, starts children as before.
