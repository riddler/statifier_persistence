defmodule StatifierPersistence.Storage do
  @moduledoc """
  The guarded entry point from a storage adapter to a
  `Statifier.MachineState.t()`.

  Every load runs through `load_position/3`, and every load is checked
  against the exact chart revision that produced the stored position
  (ADR-0003 decision 2). No adapter callback ever holds both the stored
  identity and a caller-supplied `Statifier.Machine.t()` at the same time
  (`StatifierPersistence.Storage.Adapter`'s moduledoc), so the guard cannot
  be skipped or weakened per adapter - it lives here, above every one of
  them, and nowhere else in this package decodes a position blob.

  `save_chart/3` and `save_position/3` derive a chart's `content_hash` and
  `identity_blob` from `Machine.identity/1` on the machine they are given -
  never from a caller-supplied value - and refuse an unidentified machine
  with `{:error, :unidentified_chart}` rather than writing a row a later
  load has no way to check.

  Every function here returns an error tuple instead of throwing; nothing
  in this module ever downgrades a failure to a default value.
  """

  alias Statifier.{Machine, MachineState, Position}
  alias Statifier.Machine.Identity
  alias StatifierPersistence.Storage.Adapter

  @enforce_keys [:adapter, :opts]
  defstruct [:adapter, :opts]

  @type t :: %__MODULE__{adapter: module(), opts: Adapter.opts()}

  @typedoc """
  This facade's error vocabulary: an adapter's own arms plus `Statifier`'s
  own unflattened blob-decode and identity arms (ADR-0003 decision 4).
  Every arm is returned, none is collapsed into a default.
  """
  @type error ::
          Adapter.error()
          | :not_a_statifier_blob
          | :unidentified_chart
          | {:unsupported_format_version, term()}
          | {:identity_mismatch, Identity.t(), Identity.t() | nil}

  @doc """
  Initializes `adapter` with `opts` and returns the handle every other
  function in this module takes as its first argument.
  """
  @spec new(adapter :: module(), opts :: Adapter.opts()) :: {:ok, t()} | {:error, error()}
  def new(adapter, opts) when is_atom(adapter) do
    case adapter.init(opts) do
      {:ok, adapter_opts} -> {:ok, %__MODULE__{adapter: adapter, opts: adapter_opts}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stores `chart_blob` under the content hash and identity envelope of
  `machine`'s own `Machine.identity/1` - never a caller-supplied hash.

  `chart_blob` is stored verbatim and is the one thing this function does
  not derive or inspect (ADR-0003 decision 1). Returns
  `{:error, :unidentified_chart}` when `machine` carries no identity,
  without calling the adapter at all.
  """
  @spec save_chart(store :: t(), machine :: Machine.t(), chart_blob :: binary()) ::
          :ok | {:error, error()}
  def save_chart(%__MODULE__{} = store, %Machine{} = machine, chart_blob)
      when is_binary(chart_blob) do
    case Machine.identity(machine) do
      nil ->
        {:error, :unidentified_chart}

      identity ->
        chart_record = %{
          content_hash: identity.content_hash,
          identity_blob: Identity.to_binary(identity),
          chart_blob: chart_blob
        }

        store.adapter.save_chart(store.opts, chart_record)
    end
  end

  @doc """
  Fetches the chart stored under `content_hash`.
  """
  @spec fetch_chart(store :: t(), content_hash :: Adapter.content_hash()) ::
          {:ok, Adapter.chart_record()} | {:error, error()}
  def fetch_chart(%__MODULE__{} = store, content_hash) do
    store.adapter.fetch_chart(store.opts, content_hash)
  end

  @doc """
  Encodes `machine_state` with `Position.to_binary/1` and stores it under
  `session_id`, keyed by the content hash and identity envelope of
  `machine_state.machine`'s own `Machine.identity/1` - never a
  caller-supplied hash, so a caller cannot store a position under a hash
  that disagrees with its blob.

  `{:error, :unidentified_chart}` from `Position.to_binary/1` is returned
  unchanged: st-ADR-0052 decision 4's structural guarantee that no
  unverifiable blob can be written arrives intact at this layer too.
  """
  @spec save_position(
          store :: t(),
          session_id :: Adapter.session_id(),
          machine_state :: MachineState.t()
        ) :: :ok | {:error, error()}
  def save_position(%__MODULE__{} = store, session_id, %MachineState{} = machine_state) do
    case Machine.identity(machine_state.machine) do
      nil ->
        {:error, :unidentified_chart}

      identity ->
        with {:ok, position_blob} <- Position.to_binary(machine_state) do
          position_record = %{
            session_id: session_id,
            content_hash: identity.content_hash,
            identity_blob: Identity.to_binary(identity),
            position_blob: position_blob
          }

          store.adapter.save_position(store.opts, position_record)
        end
    end
  end

  @doc """
  Fetches the position stored for `session_id` and rebuilds it into a
  `Statifier.MachineState.t()` walking `machine`, refusing a chart-revision
  mismatch instead of silently resuming the wrong configuration.

  Runs in this order, and the order is the contract:

  1. `fetch_position/2` on the adapter. `:position_not_found` and
     `{:adapter, term()}` pass straight through.
  2. The cheap pre-check: decodes the stored `identity_blob` and compares
     it against `Machine.identity(machine)` with `Identity.matches?/2` -
     never `==/2` (st-ADR-0052 decision 1). A mismatch returns
     `{:error, {:identity_mismatch, stored, supplied}}` without paying the
     position decode. `machine` carrying no identity returns
     `{:error, :unidentified_chart}`. A stored `identity_blob` that does
     not decode returns `{:error, :not_a_statifier_blob}` (or
     `{:error, {:unsupported_format_version, version}}`).
  3. `Position.from_binary/2` - the authoritative check. Its result is
     returned unchanged, all four error arms included.

  Step 2 is an optimization that must never disagree with step 3: both
  reuse `Identity.matches?/2` and produce the same
  `{:identity_mismatch, expected, actual}` arm, whichever check fires.

  The returned `MachineState.t()` carries `nil` for both `routes` and
  `invoke_types`. Neither survives the round trip: `Position.to_binary/1`
  drops both alongside `:machine` when it encodes the payload, and
  `from_binary/2` drops both from the decoded payload before it rebuilds
  the struct - unconditionally, so a blob written by an older encoder
  decodes to `nil` too (st-ADR-0064, which amends st-ADR-0052 in part).

  A caller must therefore stamp both before the next drive, via
  `MachineState.put_routes/2` and `MachineState.put_invoke_types/2`: both
  are per-drive/per-session snapshots (st-ADR-0048, st-ADR-0051), and a
  persisted position is not the place they live. Stamping is the stepper's
  job (sp-4an.2), not this function's; this function is documented here as
  the place a reader learns the snapshot does not come back.
  """
  @spec load_position(
          store :: t(),
          session_id :: Adapter.session_id(),
          machine :: Machine.t()
        ) :: {:ok, MachineState.t()} | {:error, error()}
  def load_position(%__MODULE__{} = store, session_id, %Machine{} = machine) do
    with {:ok, position_record} <- store.adapter.fetch_position(store.opts, session_id),
         :ok <- precheck_identity(position_record.identity_blob, machine) do
      Position.from_binary(position_record.position_blob, machine)
    end
  end

  @spec precheck_identity(identity_blob :: binary(), machine :: Machine.t()) ::
          :ok
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
          | {:error, :unidentified_chart}
  defp precheck_identity(_identity_blob, %Machine{identity: nil}),
    do: {:error, :unidentified_chart}

  defp precheck_identity(identity_blob, %Machine{identity: supplied_identity}) do
    with {:ok, stored_identity} <- Identity.from_binary(identity_blob) do
      if Identity.matches?(stored_identity, supplied_identity) do
        :ok
      else
        {:error, {:identity_mismatch, stored_identity, supplied_identity}}
      end
    end
  end
end
