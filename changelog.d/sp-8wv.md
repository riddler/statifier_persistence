### Added

- Adds `[:statifier_persistence, :child, :recorded]`, once per fan-out
  child answer written under the parent's settlement exclusion. Every
  index but the settling one records an answer that reaches no door, so
  this is the only surface those answers appear on (ADR-0009's sp-8wv
  amendment).
- Adds `[:statifier_persistence, :child, :settled]`, once per settlement
  decision, carrying the invocation's `policy`, the `:answer` /
  `:not_yet` decision, and the completed / failed / cancelled / unstarted
  tallies it was decided from.
- `[:statifier_persistence, :run, :step, :stop]` now carries `invoke_id`
  and `child_count`, `nil` on an ordinary drive and set on the
  `entry: :answer_parent` step, so the step span that delivers a whole
  fan-out's assembled answer is recognisable as that one.

### Changed

- `[:statifier_persistence, :child, :answered]`'s `outcome` is now the
  **invocation's** for a fan-out, not the door's: `:failed` when any index
  failed. A fan-out always answers its parent through `done_invocation/5`
  - the failure shape is inside each entry - so the event previously said
  `outcome: :done` for a settlement that had failed. It also gains
  `child_count` and `failed_count`, both `nil` for a single-child
  subchart, which is not an invocation with a width. A consumer counting
  `outcome` across fan-outs will see failures it did not see before.
