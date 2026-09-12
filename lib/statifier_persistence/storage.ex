defmodule StatifierPersistence.Storage do
  @moduledoc """
  The guarded entry point from a storage adapter to a
  `Statifier.MachineState.t()`.

  Every load executions through `load_position/3` or `load_execution_position/3`, and
  every load is checked against the exact chart revision that produced the
  stored position (ADR-0003 decision 2). No adapter callback ever holds
  both the stored identity and a caller-supplied `Statifier.Machine.t()` at
  the same time (`StatifierPersistence.Storage.Adapter`'s moduledoc), so
  the guard cannot be skipped or weakened per adapter - it lives here,
  above every one of them, and nowhere else in this package decodes a
  position blob.

  Every writer taking a machine or machine state - `save_chart/3`,
  `save_position/3`, `insert_execution/5`, `update_execution/5` - derives a chart's
  `content_hash` and `identity_blob` from `Machine.identity/1` on the
  machine it is given - never from a caller-supplied value - and refuses an
  unidentified machine with `{:error, :unidentified_chart}` rather than
  writing a row a later load has no way to check.

  A chart is keyed by that `content_hash` and by nothing else. No tenant,
  namespace, or host scope takes part in the key, so two tenants that store
  byte-identical charts share one chart row: the hash is a content address,
  saving the same one twice is `:ok`, and it does not duplicate the row
  (`StatifierPersistence.Storage.Adapter`'s `save_chart/2` contract). The
  hash answers which chart these bytes are, never who stored them.

  A multi-tenant host therefore tenant-qualifies its own per-chart rows, in
  its own tables, rather than expecting this package to do it. The package
  stores nothing per tenant; an execution's opaque `metadata` map (ADR-0006) is
  where a host tags an execution with the scope it already keys its own tables by,
  and any narrower scoping stays the host's.

  Folding a namespace into the hash would change what a chart's identity
  is, and that is `Statifier.Machine.identity/1`'s question - statifier-ex's
  contract, not this package's. Nothing here proposes it, and this package
  offers no option to do it.

  Every function here returns an error tuple instead of throwing; nothing
  in this module ever downgrades a failure to a default value.

  This module is also the storage seam's telemetry site (ADR-0009 decision
  3): every adapter callback below is timed and reported as
  `[:statifier_persistence, :adapter, :call]`, and every identity refusal
  - the guard's own and every writer's - as
  `[:statifier_persistence, :identity, :refused]`. Both are built by
  `StatifierPersistence.Telemetry`; see `docs/telemetry.md` for the
  contract.
  """

  alias Statifier.{Event, Machine, MachineState, Position}
  alias Statifier.Machine.Identity
  alias StatifierPersistence.Storage.Adapter
  alias StatifierPersistence.Telemetry

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
          | :execution_position_missing
          | :metadata_unsupported
          | :child_listing_unsupported
          | :execution_outcome_unsupported
          | :execution_states_unsupported
          | {:unsupported_format_version, term()}
          | {:identity_mismatch, Identity.t(), Identity.t() | nil}

  @typedoc """
  One decoded input log entry (ADR-0010 decision 2), as `list_inputs/2`
  returns it: the adapter's stored record with its opaque `input_blob`
  decoded back into the `%Statifier.Event{}` the interpreter saw.

  A `nil` `event` is the closed marker the cap wrote (decision 6) and
  nothing else. `door` is one of `t:StatifierPersistence.Executions.entry/0`'s
  seven atoms, as its string - the key decision 8's replay mapping is
  written against.
  """
  @type input :: %{
          execution_id: Adapter.execution_id(),
          seq: Adapter.seq(),
          door: Adapter.door(),
          event: Event.t() | nil
        }

  @typedoc """
  Options the execution writers (`insert_execution/5`, `update_execution/5`) accept:

  - `failure:` - the short reason stored on a `:failed` execution; defaults to
    `nil`.
  - `position:` - `:persist` (the default) encodes the given machine state
    with `Position.to_binary/1` and stores it as the execution's `position_blob`;
    `:skip` stores `nil` on insert and carries the currently stored blob
    forward verbatim on update.
  - `metadata:` - `insert_execution/5` only: the optional opaque map of host
    identities stored beside the execution (ADR-0006 decision 1), defaulting to
    `%{}`. It is write-once - `update_execution/5` and `update_execution_status/4`
    carry the stored map forward and accept no `metadata:` of their own.
  - `outcome_blob:` - `update_execution_status/4` only: the execution's own opaque
    answer, written once when it reaches a terminal status. Defaults to
    `nil`, which carries the stored value forward rather than clearing it,
    so every other writer leaves an answer already recorded alone.
  """
  @type execution_write_opt ::
          {:failure, String.t() | nil}
          | {:position, :persist | :skip}
          | {:metadata, Adapter.metadata()}
          | {:outcome_blob, binary() | nil}

  @doc """
  Initializes `adapter` with `opts` and returns the handle every other
  function in this module takes as its first argument.
  """
  @spec new(adapter :: module(), opts :: Adapter.opts()) :: {:ok, t()} | {:error, error()}
  def new(adapter, opts) when is_atom(adapter) do
    case adapter_call(adapter, :init, [], fn -> adapter.init(opts) end) do
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
        refuse_unidentified(:chart, [])

      identity ->
        chart_record = %{
          content_hash: identity.content_hash,
          identity_blob: Identity.to_binary(identity),
          chart_blob: chart_blob
        }

        adapter_call(store.adapter, :save_chart, [content_hash: identity.content_hash], fn ->
          store.adapter.save_chart(store.opts, chart_record)
        end)
    end
  end

  @doc """
  Fetches the chart stored under `content_hash`.
  """
  @spec fetch_chart(store :: t(), content_hash :: Adapter.content_hash()) ::
          {:ok, Adapter.chart_record()} | {:error, error()}
  def fetch_chart(%__MODULE__{} = store, content_hash) do
    adapter_call(store.adapter, :fetch_chart, [content_hash: content_hash], fn ->
      store.adapter.fetch_chart(store.opts, content_hash)
    end)
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
        refuse_unidentified(:position, session_id: session_id)

      identity ->
        with {:ok, position_blob} <- Position.to_binary(machine_state) do
          position_record = %{
            session_id: session_id,
            content_hash: identity.content_hash,
            identity_blob: Identity.to_binary(identity),
            position_blob: position_blob
          }

          keys = [session_id: session_id, content_hash: identity.content_hash]
          write(store, :save_position, keys, position_record)
        end
    end
  end

  @doc """
  Fetches the position stored for `session_id` and rebuilds it into a
  `Statifier.MachineState.t()` walking `machine`, refusing a chart-revision
  mismatch instead of silently resuming the wrong configuration.

  Executions in this order, and the order is the contract:

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
    fetch =
      adapter_call(store.adapter, :fetch_position, [session_id: session_id], fn ->
        store.adapter.fetch_position(store.opts, session_id)
      end)

    keys = [session_id: session_id]

    with {:ok, position_record} <- fetch,
         :ok <- precheck_identity(position_record.identity_blob, machine, :position, keys) do
      Position.from_binary(position_record.position_blob, machine)
    end
  end

  @doc """
  Inserts an execution record for `execution_id`, keyed by the content hash and identity
  envelope of `machine_state.machine`'s own `Machine.identity/1` - never a
  caller-supplied hash - and refusing an unidentified machine with
  `{:error, :unidentified_chart}` before calling the adapter.

  Writers always take a `MachineState`: even an execution failed at creation has
  one, because `Statifier.Interpreter.initialize/2` cannot fail (ADR-0004
  decision 1). Under `position: :persist` (the default) the state is
  encoded with `Position.to_binary/1` and stored as the execution's
  `position_blob`; under `position: :skip` the blob is stored `nil` - the
  arm for an execution with no quiescent position to store. Uniqueness comes from
  the adapter's `insert_execution/2` `:execution_exists` refusal, not a pre-check here.

  `metadata:` is the optional opaque map of host identities ADR-0006
  decision 1 grants, defaulting to `%{}`. Create is the only place it is
  set. This function is where the refusal-at-open lives: a non-empty map
  for an adapter that does not export
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1` (or whose
  answer is `false`) returns `{:error, :metadata_unsupported}` before any
  write, and an empty or absent map is never refused. A map that is not a
  map of string keys raises `ArgumentError`: the shape is the one thing
  ADR-0006 decision 1 does validate, and a malformed option is a caller
  bug, not a storage event.

  The map carries host identities only, never personal data (ADR-0006
  decision 2). `:blob_type` encryption reaches the three blob columns and
  not this map, so a name, an email address, or a card number filed here is
  at rest in the clear. Nothing in this package can enforce that - the map
  is opaque - so the contract states it and the host keeps it.
  """
  @spec insert_execution(
          store :: t(),
          execution_id :: Adapter.execution_id(),
          machine_state :: MachineState.t(),
          status :: Adapter.execution_status(),
          opts :: [execution_write_opt()]
        ) :: :ok | {:error, error()}
  def insert_execution(
        %__MODULE__{} = store,
        execution_id,
        %MachineState{} = machine_state,
        status,
        opts \\ []
      ) do
    case Machine.identity(machine_state.machine) do
      nil ->
        refuse_unidentified(:execution, execution_id: execution_id)

      identity ->
        metadata = metadata_opt!(opts)
        keys = [execution_id: execution_id, content_hash: identity.content_hash]

        with :ok <- check_metadata_supported(store, metadata),
             {:ok, position_blob} <- insert_position_blob(machine_state, position_opt(opts)) do
          record = execution_record(execution_id, status, identity, position_blob, metadata, opts)
          write(store, :insert_execution, keys, record)
        end
    end
  end

  @doc """
  Overwrites the execution stored under `execution_id` with a full record derived the
  same way `insert_execution/5` derives one: identity always from
  `machine_state.machine`'s own `Machine.identity/1`, refusal of an
  unidentified machine, `position_blob` encoded under `position: :persist`
  (the default).

  Under `position: :skip` the currently stored `position_blob` is carried
  forward verbatim: because the adapter's `update_execution/2` is a full-record
  overwrite, this function fetches the current record and reuses its blob
  bytes unchanged, so a status-only update (a failed step, an abandonment)
  never touches the stored position. Returns `{:error, :execution_not_found}`
  when no execution exists for the id.

  An execution's `metadata` is write-once (ADR-0006 decision 1 grants a map at
  create and no way to change it), so this function accepts no `metadata:`
  option and passes `%{}` in the record; the adapter carries the stored map
  forward verbatim, as
  `c:StatifierPersistence.Storage.Adapter.update_execution/2` records.
  """
  @spec update_execution(
          store :: t(),
          execution_id :: Adapter.execution_id(),
          machine_state :: MachineState.t(),
          status :: Adapter.execution_status(),
          opts :: [execution_write_opt()]
        ) :: :ok | {:error, error()}
  def update_execution(
        %__MODULE__{} = store,
        execution_id,
        %MachineState{} = machine_state,
        status,
        opts \\ []
      ) do
    case Machine.identity(machine_state.machine) do
      nil ->
        refuse_unidentified(:execution, execution_id: execution_id)

      identity ->
        keys = [execution_id: execution_id, content_hash: identity.content_hash]

        with {:ok, position_blob} <-
               update_position_blob(store, execution_id, machine_state, position_opt(opts)) do
          record = execution_record(execution_id, status, identity, position_blob, %{}, opts)
          write(store, :update_execution, keys, record)
        end
    end
  end

  @doc """
  Overwrites only the status and failure of the execution stored under `execution_id`,
  carrying every other stored field - both blobs included - forward
  verbatim.

  This is the writer for a host-driven terminal transition that has no
  `MachineState` in hand (`StatifierPersistence.Executions.fail/4`, ADR-0004
  decision 6): nothing is derived, decoded, or re-encoded, so the identity
  guard is preserved by construction - the stored `identity_blob` and
  `position_blob` bytes never change. `opts` accepts `failure:` and
  `outcome_blob:` (both default `nil`). Returns
  `{:error, :execution_not_found}` when no execution exists for the id.

  `outcome_blob:` is the one writer of an execution's own answer, and this is the
  right writer for it: an answer is recorded exactly when an execution reaches a
  terminal status, which is the transition this function exists for, and
  nothing else about the record is touched. A `nil` (the default) carries
  the stored blob forward, so a status-only update never erases an answer.
  """
  @spec update_execution_status(
          store :: t(),
          execution_id :: Adapter.execution_id(),
          status :: Adapter.execution_status(),
          opts :: [execution_write_opt()]
        ) :: :ok | {:error, error()}
  def update_execution_status(%__MODULE__{} = store, execution_id, status, opts \\ []) do
    with {:ok, execution_record} <- fetch_execution(store, execution_id) do
      updated = %{
        execution_record
        | status: status,
          failure: Keyword.get(opts, :failure),
          outcome_blob: Keyword.get(opts, :outcome_blob)
      }

      keys = [execution_id: execution_id, content_hash: execution_record.content_hash]
      write(store, :update_execution, keys, updated)
    end
  end

  @doc """
  Fetches the execution record stored under `execution_id`.
  """
  @spec fetch_execution(store :: t(), execution_id :: Adapter.execution_id()) ::
          {:ok, Adapter.execution_record()} | {:error, error()}
  def fetch_execution(%__MODULE__{} = store, execution_id) do
    adapter_call(store.adapter, :fetch_execution, [execution_id: execution_id], fn ->
      store.adapter.fetch_execution(store.opts, execution_id)
    end)
  end

  @doc """
  Whether `store`'s adapter can store an execution's opaque `metadata` map
  (ADR-0006 decision 3).

  True when the adapter exports the optional
  `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1` and it
  answers `true` for this handle. This is the predicate `insert_execution/5`'s
  refusal-at-open consults, exposed because a host choosing between an
  adapter's scope query and its own side table wants the answer before it
  writes, and because the conformance suite branches on it.
  """
  @spec metadata_supported?(store :: t()) :: boolean()
  def metadata_supported?(%__MODULE__{} = store) do
    Code.ensure_loaded?(store.adapter) and
      function_exported?(store.adapter, :supports_metadata?, 1) and
      adapter_call(store.adapter, :supports_metadata?, [], fn ->
        store.adapter.supports_metadata?(store.opts)
      end) == true
  end

  @doc """
  Whether `store`'s adapter can list executions by a metadata match (ADR-0008
  decision 5).

  True when the adapter exports the optional
  `c:StatifierPersistence.Storage.Adapter.list_executions_by_metadata/2` **and**
  `metadata_supported?/1` holds for this store. This is the predicate
  `list_executions_by_metadata/2` consults for its own refusal-at-open, exposed
  because a caller with work to do before the query - such as
  `StatifierPersistence.Driver` refusing to start a child it could never
  enumerate for cancellation - wants the answer before it acts.

  The metadata conjunct is not belt and braces. A metadata match is a
  query over stored metadata, so an adapter that declares it cannot
  support metadata (ADR-0006 decision 3) cannot answer one either, and an
  adapter whose declaration is conditional - the shipped Ecto adapter says
  `false` off Postgres, where the containment SQL does not parse - is
  otherwise reported as able to list purely because the function is
  compiled into it. Exported and able are different questions and this is
  the one callers ask (sp-11w).
  """
  @spec child_listing_supported?(store :: t()) :: boolean()
  def child_listing_supported?(%__MODULE__{} = store) do
    Code.ensure_loaded?(store.adapter) and
      function_exported?(store.adapter, :list_executions_by_metadata, 2) and
      metadata_supported?(store)
  end

  @doc """
  Whether `store`'s adapter can store an execution's own `outcome_blob` (sp-t57,
  ruling C3).

  True when the adapter exports the optional
  `c:StatifierPersistence.Storage.Adapter.supports_execution_outcome?/1` and it
  answers `true` - the same shape `metadata_supported?/1` checks. This is
  half of `StatifierPersistence.Driver.start_child_at/6`'s refusal at
  open: a fan-out child whose answer could never be read back could never
  settle its invocation.
  """
  @spec execution_outcome_supported?(store :: t()) :: boolean()
  def execution_outcome_supported?(%__MODULE__{} = store) do
    Code.ensure_loaded?(store.adapter) and
      function_exported?(store.adapter, :supports_execution_outcome?, 1) and
      adapter_call(store.adapter, :supports_execution_outcome?, [], fn ->
        store.adapter.supports_execution_outcome?(store.opts)
      end) == true
  end

  @doc """
  Whether `store`'s adapter can answer the indexed status projection
  (sp-t57, ruling C5).

  True when the adapter exports the optional
  `c:StatifierPersistence.Storage.Adapter.list_execution_states_by_metadata/2`
  and `metadata_supported?/1` holds - the same pair
  `child_listing_supported?/1` checks, and for the same reason: the
  projection is the same metadata match, narrowed to three columns. The
  other half of `start_child_at/6`'s refusal at open.
  """
  @spec execution_states_supported?(store :: t()) :: boolean()
  def execution_states_supported?(%__MODULE__{} = store) do
    Code.ensure_loaded?(store.adapter) and
      function_exported?(store.adapter, :list_execution_states_by_metadata, 2) and
      metadata_supported?(store)
  end

  @doc """
  The indexed status projection over the same match
  `list_executions_by_metadata/2` takes (sp-t57, ruling C5).

  Delegates to the adapter's optional
  `c:StatifierPersistence.Storage.Adapter.list_execution_states_by_metadata/2`
  when `execution_states_supported?/1` is true; returns
  `{:error, :execution_states_unsupported}` otherwise, without calling the
  adapter at all.

  This is the read a fan-out's settlement uses to ask whether every child
  of an invocation has reached a terminal status. It exists so that
  question does not cost N whole records - blobs included - once per
  child.
  """
  @spec list_execution_states_by_metadata(store :: t(), metadata :: Adapter.metadata()) ::
          {:ok, [Adapter.execution_state()]} | {:error, error()}
  def list_execution_states_by_metadata(%__MODULE__{} = store, metadata) do
    if execution_states_supported?(store) do
      adapter_call(store.adapter, :list_execution_states_by_metadata, [], fn ->
        store.adapter.list_execution_states_by_metadata(store.opts, metadata)
      end)
    else
      {:error, :execution_states_unsupported}
    end
  end

  @doc """
  Lists the executions whose stored `metadata` contains every key/value pair in
  `metadata` (ADR-0008 decision 5).

  Delegates to the adapter's optional
  `c:StatifierPersistence.Storage.Adapter.list_executions_by_metadata/2` when
  `child_listing_supported?/1` is true; returns
  `{:error, :child_listing_unsupported}` for an adapter that does not
  export it, without calling the adapter at all.
  """
  @spec list_executions_by_metadata(store :: t(), metadata :: Adapter.metadata()) ::
          {:ok, [Adapter.execution_record()]} | {:error, error()}
  def list_executions_by_metadata(%__MODULE__{} = store, metadata) do
    if child_listing_supported?(store) do
      adapter_call(store.adapter, :list_executions_by_metadata, [], fn ->
        store.adapter.list_executions_by_metadata(store.opts, metadata)
      end)
    else
      {:error, :child_listing_unsupported}
    end
  end

  @doc """
  Whether `store`'s adapter keeps an execution's input log (ADR-0010 decision 1).

  True when the adapter exports the optional
  `c:StatifierPersistence.Storage.Adapter.supports_input_log?/1` and it
  answers `true` - the same shape `metadata_supported?/1` checks. Nothing
  refuses on it: an adapter that keeps no log runs every chart exactly as
  it did before ADR-0010, and this predicate is public so a host that
  needs a replayable execution can find out whether it will get one *before* it
  drives one.
  """
  @spec input_log_supported?(store :: t()) :: boolean()
  def input_log_supported?(%__MODULE__{} = store) do
    Code.ensure_loaded?(store.adapter) and
      function_exported?(store.adapter, :supports_input_log?, 1) and
      adapter_call(store.adapter, :supports_input_log?, [], fn ->
        store.adapter.supports_input_log?(store.opts)
      end) == true
  end

  @doc """
  Appends `event` to `execution_id`'s input log at `door`, returning the ordinal
  the adapter assigned (ADR-0010 decisions 2 and 3).

  This is the encode site: the `%Statifier.Event{}` the interpreter was
  handed crosses the adapter seam as an opaque `input_blob`, encoded here
  with `:erlang.term_to_binary/1` in exactly `outcome_blob`'s established
  shape. ADR-0003 decision 1 therefore stays true word for word - an
  adapter sees binaries, strings and an ordinal, never a `Statifier`
  struct - and this package mints no serialization format of its own.

  `:not_supported` for an adapter that keeps no log, without calling the
  adapter at all. `{:error, :input_log_full}` once the execution's log has
  closed itself at the host's cap (decision 6): that arm refuses the
  append and never the step, and the caller carries on.

  `door` is a `t:StatifierPersistence.Executions.entry/0` atom - the fixed
  vocabulary of public doors, stored as its string.
  """
  @spec append_input(
          store :: t(),
          execution_id :: Adapter.execution_id(),
          door :: atom(),
          event :: Event.t()
        ) :: {:ok, Adapter.seq()} | :not_supported | {:error, error()}
  def append_input(%__MODULE__{} = store, execution_id, door, %Event{} = event)
      when is_atom(door) do
    if input_log_supported?(store) do
      record = %{
        execution_id: execution_id,
        seq: 0,
        door: Atom.to_string(door),
        input_blob: :erlang.term_to_binary(event)
      }

      adapter_call(store.adapter, :append_input, [execution_id: execution_id], fn ->
        store.adapter.append_input(store.opts, execution_id, record)
      end)
    else
      :not_supported
    end
  end

  @doc """
  Lists `execution_id`'s whole input log in ascending `seq`, decoded (ADR-0010
  decision 2).

  The decode half of `append_input/4`: each stored `input_blob` comes back
  as the `%Statifier.Event{}` that was delivered, equal to the one the
  interpreter saw, `caller_context` and all. An entry whose `event` is
  `nil` is the closed marker the cap wrote (decision 6) and nothing else -
  a reader that maps this log onto a replay refuses on it rather than
  replaying an execution that never happened.

  `:not_supported` for an adapter that keeps no log;
  `{:error, :execution_not_found}` for an execution that does not exist; `{:ok, []}`
  for an execution with no inputs.
  """
  @spec list_inputs(store :: t(), execution_id :: Adapter.execution_id()) ::
          {:ok, [input()]} | :not_supported | {:error, error()}
  def list_inputs(%__MODULE__{} = store, execution_id) do
    if input_log_supported?(store) do
      store.adapter
      |> adapter_call(:list_inputs, [execution_id: execution_id], fn ->
        store.adapter.list_inputs(store.opts, execution_id)
      end)
      |> decode_inputs()
    else
      :not_supported
    end
  end

  @spec decode_inputs({:ok, [Adapter.input_record()]} | {:error, error()}) ::
          {:ok, [input()]} | {:error, error()}
  defp decode_inputs({:ok, records}), do: {:ok, Enum.map(records, &decode_input/1)}
  defp decode_inputs({:error, _reason} = error), do: error

  @spec decode_input(Adapter.input_record()) :: input()
  defp decode_input(%{input_blob: nil} = record),
    do: %{execution_id: record.execution_id, seq: record.seq, door: record.door, event: nil}

  defp decode_input(record) do
    %{
      execution_id: record.execution_id,
      seq: record.seq,
      door: record.door,
      event: :erlang.binary_to_term(record.input_blob)
    }
  end

  @doc """
  Validates a writer's `metadata:` option against `store`'s adapter without
  writing anything: `:ok`, or `{:error, :metadata_unsupported}` for a
  non-empty map an adapter cannot store (ADR-0006 decision 3).

  `insert_execution/5` executions this check itself, so a caller writing through the
  facade alone never needs it. It is public for the caller that has work to
  do *before* the write and must not do it for a create that will be
  refused: `StatifierPersistence.Executions.create/4` runs it ahead of
  `Statifier.Interpreter.initialize/2` so no effect is executed for an execution
  whose metadata cannot be stored - the same reason `insert_execution/5`'s
  identity refusal runs before the position encode. Raises `ArgumentError`
  on a malformed option, exactly as the writers do.
  """
  @spec check_metadata(store :: t(), opts :: [execution_write_opt()]) :: :ok | {:error, error()}
  def check_metadata(%__MODULE__{} = store, opts) do
    check_metadata_supported(store, metadata_opt!(opts))
  end

  @doc """
  Fetches the execution stored under `execution_id` and rebuilds its position into a
  `Statifier.MachineState.t()` walking `machine`, refusing a chart-revision
  mismatch instead of silently resuming the wrong configuration.

  Executions in `load_position/3`'s order, with one extra arm: the same cheap
  identity pre-check against the stored `identity_blob`, then
  `{:error, :execution_position_missing}` for an execution whose `position_blob` is
  `nil` (an execution that failed at creation stores none - ADR-0004 decision 1),
  then `Position.from_binary/2` as the authoritative check, its result
  returned unchanged.

  Like `load_position/3`, the returned state carries `nil` for both
  `routes` and `invoke_types` (st-ADR-0064); re-stamping them before the
  next drive is the stepper's job, not this function's.
  """
  @spec load_execution_position(
          store :: t(),
          execution_id :: Adapter.execution_id(),
          machine :: Machine.t()
        ) :: {:ok, MachineState.t()} | {:error, error()}
  def load_execution_position(%__MODULE__{} = store, execution_id, %Machine{} = machine) do
    keys = [execution_id: execution_id]

    with {:ok, execution_record} <- fetch_execution(store, execution_id),
         :ok <- precheck_identity(execution_record.identity_blob, machine, :execution, keys) do
      case execution_record.position_blob do
        nil -> {:error, :execution_position_missing}
        position_blob -> Position.from_binary(position_blob, machine)
      end
    end
  end

  @spec execution_record(
          Adapter.execution_id(),
          Adapter.execution_status(),
          Identity.t(),
          binary() | nil,
          Adapter.metadata(),
          [execution_write_opt()]
        ) :: Adapter.execution_record()
  defp execution_record(execution_id, status, identity, position_blob, metadata, opts) do
    %{
      execution_id: execution_id,
      status: status,
      content_hash: identity.content_hash,
      identity_blob: Identity.to_binary(identity),
      position_blob: position_blob,
      failure: Keyword.get(opts, :failure),
      metadata: metadata,
      outcome_blob: Keyword.get(opts, :outcome_blob)
    }
  end

  # ADR-0006 decision 1's whole validation: a map with string keys. Values
  # are never inspected. A malformed option is a caller bug, so it raises
  # rather than joining the error vocabulary.
  @spec metadata_opt!([execution_write_opt()]) :: Adapter.metadata()
  defp metadata_opt!(opts) do
    case Keyword.get(opts, :metadata, %{}) do
      metadata when is_map(metadata) ->
        if Enum.all?(Map.keys(metadata), &is_binary/1) do
          metadata
        else
          raise ArgumentError,
                "the :metadata option must be a map with string keys, got keys: " <>
                  inspect(Map.keys(metadata))
        end

      other ->
        raise ArgumentError,
              "the :metadata option must be a map with string keys, got: #{inspect(other)}"
    end
  end

  # ADR-0006 decision 3's refusal at open. An empty map is never refused -
  # that is what keeps every pre-ADR-0006 adapter conformant unchanged -
  # and a non-empty one reaches the adapter only when it has declared
  # support by exporting supports_metadata?/1 and answering true.
  @spec check_metadata_supported(t(), Adapter.metadata()) :: :ok | {:error, error()}
  defp check_metadata_supported(_store, metadata) when map_size(metadata) == 0, do: :ok

  defp check_metadata_supported(store, _metadata) do
    if metadata_supported?(store), do: :ok, else: {:error, :metadata_unsupported}
  end

  @spec position_opt([execution_write_opt()]) :: :persist | :skip
  defp position_opt(opts), do: Keyword.get(opts, :position, :persist)

  @spec insert_position_blob(MachineState.t(), :persist | :skip) ::
          {:ok, binary() | nil} | {:error, error()}
  defp insert_position_blob(_machine_state, :skip), do: {:ok, nil}
  defp insert_position_blob(machine_state, :persist), do: Position.to_binary(machine_state)

  @spec update_position_blob(t(), Adapter.execution_id(), MachineState.t(), :persist | :skip) ::
          {:ok, binary() | nil} | {:error, error()}
  defp update_position_blob(_store, _execution_id, machine_state, :persist),
    do: Position.to_binary(machine_state)

  defp update_position_blob(store, execution_id, _machine_state, :skip) do
    with {:ok, execution_record} <- fetch_execution(store, execution_id) do
      {:ok, execution_record.position_blob}
    end
  end

  @spec precheck_identity(
          identity_blob :: binary(),
          machine :: Machine.t(),
          stage :: :position | :execution,
          keys :: keyword()
        ) ::
          :ok
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
          | {:error, :unidentified_chart}
  defp precheck_identity(_identity_blob, %Machine{identity: nil}, stage, keys),
    do: refuse_unidentified(stage, keys)

  defp precheck_identity(identity_blob, %Machine{identity: supplied}, stage, keys) do
    with {:ok, stored} <- Identity.from_binary(identity_blob) do
      if Identity.matches?(stored, supplied) do
        :ok
      else
        refuse_mismatch(stage, keys, stored, supplied)
      end
    end
  end

  # The two identity refusals, each emitted at exactly the site that
  # returns it (ADR-0009 decision 3). `stage` is `:chart`, `:position` or
  # `:execution`; `keys` carries whichever of `execution_id` and `session_id` the
  # refusing call is keyed by, and the rest ride as `nil`.
  #
  # Only the two content hashes travel, never the two `Identity` structs
  # the mismatch term carries (ADR-0009 decision 7): a content hash is a
  # digest of a chart document and is the key this package and its host
  # already exchange; the envelope around it is not.
  @spec refuse_unidentified(:chart | :position | :execution, keyword()) ::
          {:error, :unidentified_chart}
  defp refuse_unidentified(stage, keys) do
    Telemetry.identity_refused([stage: stage, reason: :unidentified_chart] ++ identity_keys(keys))

    {:error, :unidentified_chart}
  end

  @spec refuse_mismatch(:position | :execution, keyword(), Identity.t(), Identity.t()) ::
          {:error, {:identity_mismatch, Identity.t(), Identity.t()}}
  defp refuse_mismatch(stage, keys, stored, supplied) do
    Telemetry.identity_refused(
      [
        stage: stage,
        reason: :identity_mismatch,
        stored_content_hash: stored.content_hash,
        supplied_content_hash: supplied.content_hash
      ] ++ identity_keys(keys)
    )

    {:error, {:identity_mismatch, stored, supplied}}
  end

  @spec identity_keys(keyword()) :: keyword()
  defp identity_keys(keys),
    do: [
      execution_id: Keyword.get(keys, :execution_id),
      session_id: Keyword.get(keys, :session_id)
    ]

  # One timed adapter callback, reported as
  # `[:statifier_persistence, :adapter, :call]` (ADR-0009 decision 3).
  # `keys` is whichever of `execution_id`, `session_id` and `content_hash` this
  # callback is keyed by; the rest ride as `nil`, which is what lets a
  # handler read one shape for every callback.
  #
  # The result passes through untouched: this wrapper observes, it never
  # translates. `outcome` is `:error` only for an `{:error, _}` return,
  # which is every adapter callback's own refusal arm and also the shape
  # `supports_metadata?/1` never returns.
  @spec adapter_call(module(), atom(), keyword(), (-> result)) :: result when result: term()
  defp adapter_call(adapter, callback, keys, fun) do
    start = System.monotonic_time()
    result = fun.()

    Telemetry.adapter_call(
      System.monotonic_time() - start,
      adapter: adapter,
      callback: callback,
      outcome: call_outcome(result),
      reason: call_reason(result),
      execution_id: Keyword.get(keys, :execution_id),
      session_id: Keyword.get(keys, :session_id),
      content_hash: Keyword.get(keys, :content_hash)
    )

    result
  end

  # The four record writers, whose call shape is identical: one record
  # argument, timed and reported by `adapter_call/4`.
  @spec write(t(), atom(), keyword(), map()) :: :ok | {:error, error()}
  defp write(store, callback, keys, record) do
    adapter_call(store.adapter, callback, keys, fn ->
      apply(store.adapter, callback, [store.opts, record])
    end)
  end

  @spec call_outcome(term()) :: :ok | :error
  defp call_outcome({:error, _reason}), do: :error
  defp call_outcome(_result), do: :ok

  @spec call_reason(term()) :: term() | nil
  defp call_reason({:error, reason}), do: reason
  defp call_reason(_result), do: nil
end
