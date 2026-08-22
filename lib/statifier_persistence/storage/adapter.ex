defmodule StatifierPersistence.Storage.Adapter do
  @moduledoc """
  The storage contract: opaque blobs keyed by engine identities.

  An adapter stores and returns binaries plus engine identity strings, and
  nothing else (ADR-0003 decision 1). No callback receives a compiled
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
  A run's lifecycle status (ADR-0004 decision 2). `:completed` and `:failed`
  are terminal. No callback here validates a transition between them - the
  lifecycle above the facade owns that.
  """
  @type run_status :: :active | :completed | :failed

  @typedoc """
  A stored run (ADR-0004 decision 1): its caller-supplied key, its status,
  the content hash and identity envelope of the chart it runs, the opaque
  `position_blob` holding its current position - nullable, because a run
  that fails at creation has no quiescent position to store - and a short
  `failure` reason for a `:failed` run, `nil` otherwise.
  """
  @type run_record :: %{
          run_id: run_id(),
          status: run_status(),
          content_hash: content_hash(),
          identity_blob: binary(),
          position_blob: binary() | nil,
          failure: String.t() | nil
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
  a duplicate `run_id`; `{:adapter, term()}` carries a backend failure (a
  database down, a timeout) that is not this layer's to interpret further.
  """
  @type error ::
          :chart_not_found
          | :position_not_found
          | :run_exists
          | :run_not_found
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
  decision 1).
  """
  @callback fetch_run(opts(), run_id()) ::
              {:ok, StatifierPersistence.Storage.Adapter.run_record()} | {:error, error()}

  @doc """
  Overwrites the run stored under `run_record`'s `run_id` with the full
  record.

  Returns `{:error, :run_not_found}` when no run exists for the id. This is
  a full-record overwrite - there is no partial-update surface, so every
  field in the stored row after this call is the given record's, including
  a `nil` `position_blob`. Like the other run callbacks it decodes nothing,
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

  @optional_callbacks isolate: 1
end
