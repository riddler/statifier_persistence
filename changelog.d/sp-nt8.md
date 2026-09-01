### Added

- `StatifierPersistence.Runs.cancel/3` retains a run's record and position
  while moving its status to the new terminal `:cancelled` state - a
  host-driven transition alongside `fail/4`, and one an already-terminal run
  discards rather than re-writes.
- An adapter can now optionally export `list_runs_by_metadata/2` to let a
  host enumerate the runs whose metadata contains a given set of key/value
  pairs; `StatifierPersistence.Storage.list_runs_by_metadata/2` and
  `child_listing_supported?/1` expose this through the facade, returning
  `{:error, :child_listing_unsupported}` for an adapter that does not
  support it. `StatifierPersistence.Storage.InMemory` implements it now,
  alongside the existing `StatifierPersistence.Storage.Ecto` support.
- `StatifierPersistence.Run.Linkage` records a durable subchart child's
  parent under a reserved, package-owned key in run `metadata` (ADR-0008
  decision 2): the parent's run id, the invocation id, a child index, and
  a mandatory pin of the child's own chart identity. `Runs.create/4` gains
  a `linkage:` option that stores it and raises `ArgumentError` if a host's
  own `metadata:` tries to write into the reserved key.
- `StatifierPersistence.Driver`'s `:dispatch` fun can now answer
  `{:start_child, invoke, {:invoke, invoke}}` - the same instruction
  `Statifier.Session.Effects` plans in-memory - to start a durable
  subchart (ADR-0008 decision 3). The child is created as an ordinary run
  under the parent's own exclusion, linked and pinned through
  `StatifierPersistence.Run.Linkage`, driven to its own quiescence through
  the same loop (so a child that itself invokes a grandchild is handled
  with no extra code), and answered `:pending` so the parent rests with
  the invocation live. A store whose adapter cannot enumerate its children
  refuses before any write, and a crash between the child's creation and
  the parent's own persist is a safe re-drive rather than a duplicate
  child. Every refusal here answers `error.communication.invoke.<id>` with
  reason `"child_run_creation_failed"`. A host that never returns this arm
  sees no behavior change.
- `StatifierPersistence.Run` gains `donedata`, set from a completing run's
  `:done` effect and `nil` on every other step or stored record - a
  position that has reached a final state has no configuration left to
  carry it, so this is the only moment it exists.
- A durable subchart child now answers its parent (ADR-0008 decision 3).
  `StatifierPersistence.Driver.new/3` gains a `chart_resolver:` option -
  `(content_hash -> {:ok, Statifier.Machine.t()} | :error)` - and, once
  set, `create/3`, `send_event/4`, `done_invocation/5` and
  `failed_invocation/5` automatically answer a completed or permanently
  failed child's parent through `done_invocation/5` or `failed_invocation/5`
  under the parent's own exclusion, carrying the child's donedata or
  failure reason. `StatifierPersistence.Driver.parent_link/2` reads a run's
  own linkage back (`:no_parent` for an ordinary run), and
  `StatifierPersistence.Driver.answer_parent/3` is the public door a host
  with no `chart_resolver:` calls explicitly - the same function the
  automatic path uses once the resolver has produced a driver over the
  parent's chart. A parent that has already cancelled the invocation
  answers `{:discarded, _}`, which is the existing late-answer discard
  doing its job, not a new failure mode.
- A durable subchart is now cancelled, along with its own children
  recursively, when its parent leaves the invoking state (ADR-0008
  decision 5) - a chart's own `timeout` transition out of an invoking
  state being the ordinary case. `StatifierPersistence.Runs.cascade_cancel/3`
  walks the linked subtree and `cancel/3`s every run in it; nothing is
  deleted and every position is left byte-identical, so a cancelled
  subtree is retained as the evidence of what a timed-out workflow was
  doing when the deadline hit. The walk is idempotent - re-running it over
  an already-cancelled subtree writes nothing, and one interrupted partway
  by a crash is completed correctly by re-running it - and it needs no
  depth ceiling, because a child's run id strictly extends its parent's, so
  the run tree is acyclic by construction. A completion that arrives for a
  cancelled invocation is dropped by the existing late-answer discard, with
  no new mechanism.
