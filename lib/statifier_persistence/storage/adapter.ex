defmodule StatifierPersistence.Storage.Adapter do
  @moduledoc """
  The storage contract: opaque blobs keyed by engine identities.

  An adapter stores and returns binaries, engine identity strings, and one
  optional opaque map of host identities on a run record - and nothing else
  (ADR-0003 decision 1 as amended by ADR-0006). No callback receives a compiled
  `Statifier.Machine` and none returns a `Statifier.MachineState` value -
  the identity guard is not a callback here, and cannot be, because no
  callback ever holds both the stored identity and a caller-supplied machine
  at the same time. The guard lives above every adapter, in
  `StatifierPersistence.Storage.load_position/3` (ADR-0003 decision 2).

  A chart is keyed by its content hash
  (`Statifier.Machine.Identity.content_hash`, verbatim); a position is keyed
  by the engine session id (st-ADR-0008's `sess_` UXID), also verbatim; a
  run is keyed by a caller-supplied opaque `run_id`, also verbatim
  (ADR-0004 decision 2). All are opaque strings to this layer: no callback
  here accepts or returns a surrogate key, a table name, or a prefix
  (ADR-0002 decision 1, ADR-0003 decision 3).
  """

  @typedoc """
  Adapter configuration, opaque to this package. `init/1` returns the value
  a caller then threads through every other callback as this adapter's
  handle - a pid, a name, a repo module, whatever the adapter needs.
  """
  @type opts :: keyword()

  @typedoc "A chart's content hash, verbatim from `Statifier.Machine.Identity` (ADR-0002 decision 1)."
  @type content_hash :: String.t()

  @typedoc "An engine session id (st-ADR-0008), verbatim."
  @type session_id :: String.t()

  @typedoc """
  A run's key: a caller-supplied opaque string, stored verbatim (ADR-0004
  decision 2). A host identity in ADR-0002 decision 1's category - never a
  surrogate this layer generates.
  """
  @type run_id :: String.t()

  @typedoc """
  A run's lifecycle status (ADR-0004 decision 2, extended by ADR-0008
  decision 5). `:completed`, `:failed` and `:cancelled` are terminal. No
  callback here validates a transition between them - the lifecycle above
  the facade owns that.
  """
  @type run_status :: :active | :completed | :failed | :cancelled

  @typedoc """
  A run's optional opaque metadata (ADR-0006 decision 1): a map of string
  keys to host-supplied values, opaque here in the strong sense
  `chart_blob` is opaque. No callback reads a key or a value to make a
  decision, validates it beyond the shape, or merges it into a blob.

  The map carries **host identities only, never personal data** (ADR-0006
  decision 2): a tenant id, a subject-entity id, a correlation id - never a
  name, an email address, a postal address, a card number, or any other
  personal or cardholder data. Blob encryption (`:blob_type`) covers the
  three blob columns and does not reach this map, so anything filed here is
  at rest in the clear. This package cannot enforce the rule - the map is
  opaque by decision 1 - so the contract states it and the host keeps it.

  The empty map means "no metadata" and is what an absent map resolves to.
  """
  @type metadata :: %{optional(String.t()) => term()}

  @typedoc """
  A stored run (ADR-0004 decision 1): its caller-supplied key, its status,
  the content hash and identity envelope of the chart it runs, the opaque
  `position_blob` holding its current position - nullable, because a run
  that fails at creation has no quiescent position to store - a short
  `failure` reason for a `:failed` run, `nil` otherwise, and the opaque
  `metadata` map of host identities (ADR-0006 decision 1), `%{}` when the
  caller supplied none.
  """
  @type run_record :: %{
          run_id: run_id(),
          status: run_status(),
          content_hash: content_hash(),
          identity_blob: binary(),
          position_blob: binary() | nil,
          failure: String.t() | nil,
          metadata: metadata()
        }

  @typedoc """
  A stored chart: its content hash, its identity envelope
  (`Statifier.Machine.Identity.to_binary/1`), and an opaque `chart_blob`
  this layer does not decode, inspect, or say what produced (ADR-0003
  decision 1).
  """
  @type chart_record :: %{
          content_hash: content_hash(),
          identity_blob: binary(),
          chart_blob: binary()
        }

  @typedoc """
  A stored position: the engine session id it belongs to, the content hash
  and identity envelope of the chart it was saved against, and the opaque
  `position_blob` (`Statifier.Position.to_binary/1`'s output) this layer
  does not decode.
  """
  @type position_record :: %{
          session_id: session_id(),
          content_hash: content_hash(),
          identity_blob: binary(),
          position_blob: binary()
        }

  @typedoc """
  This layer's own refusal arms. `:chart_not_found`, `:position_not_found`,
  and `:run_not_found` are the not-found arms every adapter must return
  instead of `nil` or a raise; `:run_exists` is `insert_run/2`'s refusal of
  a duplicate `run_id`; `:metadata_unsupported` is the refusal-at-open arm
  for a non-empty `metadata` map an adapter cannot store (ADR-0006
  decision 3); `{:adapter, term()}` carries a backend failure (a
  database down, a timeout) that is not this layer's to interpret further.
  """
  @type error ::
          :chart_not_found
          | :position_not_found
          | :run_exists
          | :run_not_found
          | :metadata_unsupported
          | {:adapter, term()}

  @doc """
  Prepares this adapter for use and returns the handle every other callback
  is called with as its first argument.

  For an adapter that needs setup - starting an Agent, checking a repo is
  reachable - this is the declared place for it, and the return value is
  the opts a caller threads through `save_chart/2`, `fetch_chart/2`,
  `save_position/2`, and `fetch_position/2`. An adapter needing no setup
  returns `{:ok, opts}` unchanged.
  """
  @callback init(opts()) :: {:ok, opts()} | {:error, error()}

  @doc """
  Stores `chart_record`, idempotent on its `content_hash`.

  A content hash is a content address: saving the same hash twice is `:ok`
  and must not duplicate the row or change what a later `fetch_chart/2`
  returns for it. This callback does not inspect, decode, or validate
  `chart_blob`'s bytes and performs no identity check - both are outside
  this layer's job (ADR-0003 decisions 1 and 2).
  """
  @callback save_chart(opts(), StatifierPersistence.Storage.Adapter.chart_record()) ::
              :ok | {:error, error()}

  @doc """
  Fetches the chart stored under `content_hash`.

  Returns `{:error, :chart_not_found}` when no chart is stored under that
  hash - never `{:ok, nil}` and never a raise. The returned `chart_blob` and
  `identity_blob` must be byte-identical to what `save_chart/2` was given;
  an adapter must not normalize, truncate, or re-encode them.
  """
  @callback fetch_chart(opts(), content_hash()) ::
              {:ok, StatifierPersistence.Storage.Adapter.chart_record()} | {:error, error()}

  @doc """
  Stores `position_record`, overwriting any position already stored for its
  `session_id`.

  A session has exactly one current position; this layer keeps no history
  of prior saves. This callback does not decode or validate `position_blob`
  and performs no identity check, for the same reason `save_chart/2` does
  not: the guard belongs to the facade, above every adapter (ADR-0003
  decision 2).
  """
  @callback save_position(opts(), StatifierPersistence.Storage.Adapter.position_record()) ::
              :ok | {:error, error()}

  @doc """
  Fetches the position stored for `session_id`.

  Returns `{:error, :position_not_found}` when no position is stored for
  that session id - never `{:ok, nil}` and never a raise. The returned
  `position_blob` and `identity_blob` must be byte-identical to what
  `save_position/2` was given.
  """
  @callback fetch_position(opts(), session_id()) ::
              {:ok, StatifierPersistence.Storage.Adapter.position_record()} | {:error, error()}

  @doc """
  Inserts `run_record`, refusing a duplicate `run_id` with
  `{:error, :run_exists}`.

  The refusal must be atomic with the write: no interleaving of two
  `insert_run/2` calls for the same `run_id` may let both return `:ok`.
  Create-exactly-once rests on this callback alone, without a lock, so a
  check-then-insert implemented as two separate operations does not satisfy
  the contract - a SQL adapter reaches for a unique index (or equivalent
  backend-native uniqueness) and maps its violation to
  `{:error, :run_exists}`.

  This callback does not decode `position_blob` or `identity_blob`, does
  not validate the status, and performs no identity check - the facade and
  the lifecycle own those (ADR-0003 decisions 1 and 2, ADR-0004
  decision 1).

  `metadata` is stored as given and read back by `fetch_run/2` unchanged
  (ADR-0006 decision 1). Insert is the only write that sets it: the map is
  not mutable after create, and `update_run/2` says so. An adapter reaching
  this callback has already declared `supports_metadata?/1` true for a
  non-empty map - the facade refuses at open otherwise - but an adapter
  whose backend cannot hold a particular value (a `jsonb` column and a
  tuple, say) refuses that value here with
  `{:error, :metadata_unsupported}` rather than storing something else.
  """
  @callback insert_run(opts(), StatifierPersistence.Storage.Adapter.run_record()) ::
              :ok | {:error, error()}

  @doc """
  Fetches the run stored under `run_id`.

  Returns `{:error, :run_not_found}` when no run is stored under that id -
  never `{:ok, nil}` and never a raise. The returned `identity_blob` and
  `position_blob` must be byte-identical to what was stored (a stored `nil`
  `position_blob` comes back as `nil`); an adapter must not normalize,
  truncate, or re-encode them, and it does not decode them either (ADR-0003
  decision 1). The returned `metadata` is the map `insert_run/2` stored,
  unchanged, and `%{}` when none was stored - never `nil`.
  """
  @callback fetch_run(opts(), run_id()) ::
              {:ok, StatifierPersistence.Storage.Adapter.run_record()} | {:error, error()}

  @doc """
  Overwrites the run stored under `run_record`'s `run_id` with the full
  record.

  Returns `{:error, :run_not_found}` when no run exists for the id. This is
  a full-record overwrite - there is no partial-update surface, so every
  field in the stored row after this call is the given record's, including
  a `nil` `position_blob`.

  `metadata` is the one exception, and it is an exception by decision:
  ADR-0006 decision 1 grants a map supplied at create and grants no way to
  change it afterwards, so this callback carries the stored map forward
  verbatim and ignores the `metadata` field of the record it is given. The
  facade passes `%{}` there for exactly that reason. An adapter that
  overwrote it would make the map mutable, which is the reopener ADR-0006's
  consequences name rather than a behaviour it grants.

  Like the other run callbacks it decodes nothing,
  validates no status transition, and performs no identity check - the
  facade and the lifecycle own those (ADR-0003 decisions 1 and 2, ADR-0004
  decision 1).
  """
  @callback update_run(opts(), StatifierPersistence.Storage.Adapter.run_record()) ::
              :ok | {:error, error()}

  @doc """
  Optional per-test isolation hook (ADR-0003 amendment, 2026-08-21).

  The conformance suite's case template (`StorageConformance`, in this
  package's `Testing` namespace) calls this before each generated test,
  when an adapter exports it, so an adapter backed by a
  shared resource - a database connection, a sandbox checkout - can wrap
  every test in its own isolated unit (an `Ecto.Adapters.SQL.Sandbox`
  checkout, for one) instead of leaking state between conformance tests.
  Optional and defaulted to a no-op by the template's own
  `function_exported?/3` check: an adapter needing no isolation, like
  `StatifierPersistence.Storage.InMemory`, simply does not implement it.
  """
  @callback isolate(opts()) :: :ok | {:error, error()}

  @doc """
  Optional per-run lock (ADR-0003 amendment, 2026-08-22; ADR-0004
  decision 5).

  Provides mutual exclusion per `run_id`: while one `lock_run/3` call for a
  given `run_id` is running `fun`, no other `lock_run/3` call for the same
  `run_id` may run its own. `fun` runs while the exclusion is held, and the
  exclusion is released on ANY exit from `fun` - a normal return, a throw,
  and a raise escaping `fun` alike. The lock must not leak: a raising `fun`
  propagates to the caller, but the next `lock_run/3` for that `run_id`
  must still acquire.

  This is the callback the default serialization strategy
  (`StatifierPersistence.Serialization.AdapterLock`) delegates to; an
  adapter that does not export it makes that strategy refuse with
  `{:error, {:serialization, :not_supported}}`. The Ecto adapter
  implements it as a transaction-scoped advisory lock plus a
  `SELECT ... FOR UPDATE` row lock inside a transaction that spans `fun`
  (ADR-0004 decision 5 as amended 2026-08-22) - the advisory half exists
  because a row lock alone excludes nothing for a `run_id` whose run has
  not been inserted yet.
  """
  @callback lock_run(opts(), run_id(), (-> result)) ::
              {:ok, result} | {:error, error()}
            when result: var

  @doc """
  Optional declaration that this adapter can store a run's `metadata` map
  (ADR-0006 decision 3).

  Exporting it and returning `true` is how an adapter opts into the
  metadata contract - the same `@optional_callbacks` plus
  `function_exported?/3` shape `isolate/1` and `lock_run/3` use. An adapter
  that does not export it stores no metadata, and
  `StatifierPersistence.Storage.insert_run/5` refuses a non-empty map for
  it at open with `{:error, :metadata_unsupported}` before any write
  happens. An empty or absent map is never refused, which is what keeps
  every adapter written before ADR-0006 conformant without a line of
  change.

  The refusal is at open - at the create that supplies the map - so a host
  learns on its first call rather than discovering a silently dropped scope
  on a later fetch. Refusing is conformance, not a gap.
  """
  @callback supports_metadata?(opts()) :: boolean()

  @doc """
  Optional metadata-match listing (ADR-0006 decision 3's equality-match
  helper, promoted to a callback by ADR-0008 decision 5).

  Lists the runs whose stored `metadata` contains every key/value pair in
  `metadata`, recursively for a nested map. Equality match on all pairs is
  the whole query surface - no ranges, no partial matches, no ordering
  guarantee - the same contract `StatifierPersistence.Storage.Ecto`'s
  module-local function already documents. Exporting it is how an adapter
  declares it can answer "which runs name me as their parent", which is
  what a cascading cancel walks; an adapter that does not export it cannot
  host a durable subchart, and `StatifierPersistence.Driver` refuses at
  open rather than starting a child it could never cancel.
  """
  @callback list_runs_by_metadata(opts(), metadata()) ::
              {:ok, [StatifierPersistence.Storage.Adapter.run_record()]} | {:error, error()}

  @optional_callbacks isolate: 1,
                      lock_run: 3,
                      supports_metadata?: 1,
                      list_runs_by_metadata: 2
end
