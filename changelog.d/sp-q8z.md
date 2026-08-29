### Changed

- Requires `statifier` from its git `main` (ref `1f865f7`) rather than `~> 2.0`,
  until a release carries the queue-discard-on-exit fix.

### Fixed

- A run whose top-level `<final>` is reached while sibling `done.state.*` events
  are still queued now persists as `completed`, instead of raising
  "loop bug: non-quiescent MachineState reached the persist tail". The same
  holds for a top-level `<final>` whose `<donedata>` expression fails.
