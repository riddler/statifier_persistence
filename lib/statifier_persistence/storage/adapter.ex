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
  by the engine session id (st-ADR-0008's `sess_` UXID), also verbatim. Both
  are opaque strings to this layer: no callback here accepts or returns a
  surrogate key, a table name, or a prefix (ADR-0002 decision 1, ADR-0003
  decision 3).
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
  This layer's own refusal arms. `:chart_not_found` and `:position_not_found`
  are the not-found arms every adapter must return instead of `nil` or a
  raise; `{:adapter, term()}` carries a backend failure (a database down, a
  timeout) that is not this layer's to interpret further.
  """
  @type error ::
          :chart_not_found
          | :position_not_found
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
end
