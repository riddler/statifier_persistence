### Added

- **Durable subchart composition** (ADR-0008): a `<invoke>` whose `:dispatch`
  fun answers `{:start_child, invoke, {:invoke, invoke}}` - the same
  instruction `Statifier.Session.Effects` plans in-memory, unchanged - now
  starts, links, answers, and cancels a subchart as an ordinary durable run
  rather than refusing it.
  - The child is created under the parent's own exclusion as a run in its
    own right: its own `run_id` (derived deterministically from the
    parent's, the invocation id, and a child index, so an at-least-once
    re-drive after a crash finds the same child instead of duplicating it),
    guarded by the same content-hash identity check as any run, and driven
    to its own quiescence through this same loop - so a child that itself
    invokes a grandchild needs no extra code. `StatifierPersistence.Driver`
    answers `:pending` once the child exists, so the parent rests with the
    invocation live and no process holding it, for as long as the child
    takes. A store whose adapter cannot enumerate its children refuses
    before any write, and every refusal here answers
    `error.communication.invoke.<id>` with reason
    `"child_run_creation_failed"`. A host that never returns the new
    `:dispatch` arm sees no behavior change.
  - `StatifierPersistence.Run.Linkage` records the parent-child
    relationship under a reserved, package-owned key in the child's run
    `metadata` (ADR-0008 decision 2): the parent's run id, the invocation
    id, a child index, and a mandatory pin of the child's own chart
    identity, checked on every reload the same way any run's identity is.
    `Runs.create/4` gains the `linkage:` option that stores it and raises
    `ArgumentError` if a host's own `metadata:` tries to write into the
    reserved key.
  - A child that completes answers its parent automatically.
    `StatifierPersistence.Driver.new/3` gains a `chart_resolver:` option -
    `(content_hash -> {:ok, Statifier.Machine.t()} | :error)`, needed
    because a stored chart is opaque to this package - and once set,
    every drive entry point resolves a completed or permanently failed
    child's parent and answers it through the same `done_invocation/5` /
    `failed_invocation/5` doors any asynchronous host uses, carrying the
    child's donedata or failure reason. `StatifierPersistence.Run` gains
    `donedata` for exactly this handoff - present only on the step that
    completes a run, `nil` everywhere else, never persisted.
    `StatifierPersistence.Driver.parent_link/2` and `answer_parent/3` are
    the public doors underneath, for a host with no `chart_resolver:` to
    call explicitly. A parent that has already cancelled the invocation by
    the time its child answers is simply discarded, the same late-answer
    discard any asynchronous call already gets - not a new failure mode.
  - When a parent leaves the invoking state - a timeout being the ordinary
    case - its child, and that child's own children recursively, are
    cancelled: `StatifierPersistence.Runs.cancel/3` and the new
    `cascade_cancel/3` walk the linked subtree, moving every run to a new
    terminal `:cancelled` status. Nothing is deleted and every position is
    left byte-identical, so a cancelled subtree stays on hand as the
    evidence of what a timed-out workflow was doing when the deadline hit.
    The cascade is idempotent - re-running it over an already-cancelled
    subtree writes nothing, and one interrupted by a crash partway through
    is completed correctly by re-running it - and needs no depth ceiling,
    since a child's run id strictly extends its parent's and the run tree
    is acyclic by construction. This holds up across a restart: a
    completion racing a cancel across a parent that has gone cold, or
    landing while the parent's own answering step is mid-flight, is always
    discarded rather than delivered to a subtree that no longer exists,
    because the liveness check and the step it gates share one exclusion.
  - An adapter can now optionally export `list_runs_by_metadata/2`, letting
    a host enumerate the runs whose metadata contains a given set of
    key/value pairs - the query the cascade above is built on.
    `StatifierPersistence.Storage.list_runs_by_metadata/2` and
    `child_listing_supported?/1` expose this through the facade, returning
    `{:error, :child_listing_unsupported}` for an adapter that does not
    support it. `StatifierPersistence.Storage.InMemory` implements it now,
    alongside the existing `StatifierPersistence.Storage.Ecto` support.
