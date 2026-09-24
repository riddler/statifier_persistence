defmodule StatifierPersistence.Storage.Adapter do
  @moduledoc """
  The storage contract: opaque blobs keyed by engine identities.

  An adapter stores and returns binaries, engine identity strings, and one
  optional opaque map of host identities on an execution record - and nothing else
  (ADR-0003 decision 1 as amended by ADR-0006). No callback receives a compiled
  `Statifier.Machine` and none returns a `Statifier.MachineState` value -
  the identity guard is not a callback here, and cannot be, because no
  callback ever holds both the stored identity and a caller-supplied machine
  at the same time. The guard lives above every adapter, in
  `StatifierPersistence.Storage.load_position/3` (ADR-0003 decision 2).

  A chart is keyed by its content hash
  (`Statifier.Machine.Identity.content_hash`, verbatim); a position is keyed
  by the engine session id (st-ADR-0008's `sess_` UXID), also verbatim; an
  execution is keyed by a caller-supplied opaque `execution_id`, also
  verbatim (ADR-0004 decision 2). All are opaque strings to this layer: no callback
  here accepts or returns a surrogate key, a table name, or a prefix
  (ADR-0002 decision 1, ADR-0003 decision 3).

  ## The input log is a data-retention decision, not a debugging switch

  An adapter that exports `supports_input_log?/1` and answers `true`
  stores every input the interpreter saw, verbatim, for the life of the
  execution (ADR-0010). Chart blobs, position blobs and identity blobs are
  engine-shaped; an event's `data` is the host's own values - a signup's
  email address, a capture's card number - and turning the log on puts
  them at rest. `:blob_type` reaches `input_blob` for exactly that reason
  (ADR-0010 decision 4), and `input_log_cap:` bounds how much of it
  accumulates (decision 6), but a host that cannot encrypt at rest and
  cannot accept plaintext payloads declines the whole facility by not
  exporting the callback. Nothing in this package refuses an execution over it.
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
  An execution's key: a caller-supplied opaque string, stored verbatim (ADR-0004
  decision 2). A host identity in ADR-0002 decision 1's category - never a
  surrogate this layer generates.
  """
  @type execution_id :: String.t()

  @typedoc """
  An execution's lifecycle status (ADR-0004 decision 2, extended by ADR-0008
  decision 5 and ADR-0014 decision 1): five arms. `:completed`, `:failed`
  and `:cancelled` are terminal. `:active` and `:needs_migration` are not:
  `:needs_migration` is an execution a migration parked on the chart it
  was already pinned to, which takes no event until it leaves the arm
  (ADR-0014 decision 2). No callback here validates a transition between
  them - the lifecycle above the facade owns that.
  """
  @type execution_status :: :active | :needs_migration | :completed | :failed | :cancelled

  @typedoc """
  An execution's optional opaque metadata (ADR-0006 decision 1): a map of string
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
  A stored execution (ADR-0004 decision 1): its caller-supplied key, its status,
  the content hash and identity envelope of the chart it runs, the opaque
  `position_blob` holding its current position - nullable, because an execution
  that fails at creation has no quiescent position to store - a short
  `failure` reason for a `:failed` execution, `nil` otherwise, the opaque
  `metadata` map of host identities (ADR-0006 decision 1), `%{}` when the
  caller supplied none, and the opaque `outcome_blob`.

  `outcome_blob` is the execution's own answer, written once when it reaches a
  terminal status and `nil` for every execution that has none - which is almost
  all of them, since an ordinary execution answers nobody. It is opaque in
  `position_blob`'s strong sense: this layer does not decode it, does not
  say what produced it, and never reads it to make a decision. It exists
  because a stored record otherwise carries no trace of what a completed
  execution answered with, and a fan-out's settlement has to assemble N answers
  it did not witness.

  `ended_at` is the time of the first terminal write the row received
  while it had no stamp, and `nil` until then. A record that carries an
  execution into a terminal status carries the stamp, and
  `c:update_execution/2` keeps a stored stamp over any later record's, so
  once written it does not move, however often the row is written
  afterwards. Two cases follow from that rule rather than from the
  status. A stamp stays when a later write puts the row back to a status
  that is not terminal, so such a row carries a stamp while it is not
  terminal. And a row that was already terminal before its store could
  hold the field has no stamp until a later terminal write stamps it
  with that write's time. This layer does not decide what a stamp is -
  `StatifierPersistence.Storage`'s writers choose it - and
  `c:insert_execution/2` stores the one it is given.
  """
  @type execution_record :: %{
          execution_id: execution_id(),
          status: execution_status(),
          content_hash: content_hash(),
          identity_blob: binary(),
          position_blob: binary() | nil,
          failure: String.t() | nil,
          metadata: metadata(),
          outcome_blob: binary() | nil,
          ended_at: DateTime.t() | nil
        }

  @typedoc """
  One row of the indexed status projection
  (`c:list_execution_states_by_metadata/2`): a matched execution's id, its status, and
  the `child_index` from this package's own reserved linkage namespace -
  `nil` for a matched execution that carries no linkage.

  Deliberately not a `execution_record`: the projection exists so that "have all
  N of this invocation's children settled?" can be answered without moving
  N identity and position blobs, and a row carrying them would defeat the
  reason the callback exists.
  """
  @type execution_state :: %{
          execution_id: execution_id(),
          status: execution_status(),
          child_index: non_neg_integer() | nil
        }

  @typedoc """
  The drained query's answer for one content hash (ADR-0012 decision 3): a
  count of execution rows on that hash in each stored arm, plus `children`.

  Every key is always present and every value is a count, so an unknown
  hash answers zeros rather than an empty map or a miss - "nothing is
  running on this chart" is an answer, not an absence.

  The five arm keys are the stored statuses of `t:execution_status/0` and
  nothing else: there is no `terminal` key, because terminal is a fold
  this package names in prose and never stores (decision 2). A reader
  that wants the fold adds the three terminal arms. `needs_migration` is
  not one of them (ADR-0014 decision 4).

  `children` counts the durable-child linkage pins naming that hash whose
  parent execution is `:active` or `:needs_migration` - the pin decision
  1 counts, as ADR-0014 decision 4 reads it, which is not an execution
  row on the hash and so is not one of the five arms.
  """
  @type execution_counts :: %{
          active: non_neg_integer(),
          needs_migration: non_neg_integer(),
          completed: non_neg_integer(),
          failed: non_neg_integer(),
          cancelled: non_neg_integer(),
          children: non_neg_integer()
        }

  @typedoc """
  One pin source's own named counts, under the module that answered them
  (ADR-0012 decision 4). The names are the source's to choose; this layer
  neither reads nor interprets them, and only asks whether any is
  non-zero.
  """
  @type source_counts :: %{module() => %{atom() => non_neg_integer()}}

  @typedoc """
  What a retirement is refused with (ADR-0012 decision 5): every count
  the refusal knows, this package's own under its own name and each
  source's under that source's module name.

  Deliberately not `t:execution_counts/0`. The drained query answers
  "what is running on this chart" and keeps its flat keys; this answers
  "what would I break", so the five execution arms are
  nested under `:executions` to keep them distinguishable from the two
  counts that are not execution rows at all, and `:positions` and
  `:sources` are here and are not in the drained query's map.

  Only these block a retirement: `executions.active`,
  `executions.needs_migration` (a parked execution pins its chart,
  ADR-0014 decision 4), `children`, `positions`, and any non-zero count
  under any source. The three terminal execution arms are reported and
  never block, because a
  terminal row never goes away and counting one would make a chart
  permanently unretirable the first time anything on it finished
  (ADR-0012 decision 1).
  """
  @type pin_counts :: %{
          executions: %{
            active: non_neg_integer(),
            needs_migration: non_neg_integer(),
            completed: non_neg_integer(),
            failed: non_neg_integer(),
            cancelled: non_neg_integer()
          },
          children: non_neg_integer(),
          positions: non_neg_integer(),
          sources: source_counts()
        }

  @typedoc """
  The tombstone a retirement writes and the counts it is decided against
  (ADR-0012 decisions 5 and 6): when it was retired, the opaque host
  string recording who asked, and the pin-source counts the layer above
  this one already collected.

  `sources` is carried into the callback rather than checked above it
  because decision 6 makes the count and the write one atomic unit: a
  source count that blocks has to block inside the same unit that would
  otherwise write, so that no path writes a tombstone the counts did not
  clear.
  """
  @type retirement :: %{
          retired_at: DateTime.t(),
          retired_by: String.t(),
          sources: source_counts()
        }

  @typedoc """
  A tombstoned chart's own record of its retirement (ADR-0012 decision
  6): when, and the opaque host string saying who. It is what the
  retired arm of both chart doors carries, so a host reads its own
  decision back rather than a miss.
  """
  @type retired_info :: %{
          retired_at: DateTime.t(),
          retired_by: String.t() | nil
        }

  @typedoc """
  One write of a tree migration's unit (`c:write_tree_migration/2`,
  ADR-0015 decision 3).

  - `{:repin, execution_record, linkage_content_hash}` - the record the
    one write of `StatifierPersistence.Executions.migrate/4` would carry
    for this execution: its identity, content hash and position blob on
    the chart it moves to, the status `:active` and a `nil` failure. The
    stored `metadata` and `outcome_blob` are carried forward as
    `c:update_execution/2` carries them. `linkage_content_hash` is the new
    `content_hash` of the execution's linkage pin when it carries a
    linkage (ADR-0008's 2026-09-23 Amendment), and `nil` for an execution
    that carries none; only that one key under the reserved namespace is
    rewritten.
  - `{:park, execution_id}` - the status `:needs_migration` and a `nil`
    failure, every other stored field carried forward, as
    `StatifierPersistence.Storage.update_execution_status/4` writes a
    status (ADR-0014 decision 1).
  """
  @type tree_write ::
          {:repin, execution_record(), content_hash() | nil}
          | {:park, execution_id()}

  @typedoc """
  An execution's input log ordinal: dense, zero-based, per execution, assigned by the
  adapter. Not a position blob (ADR-0010 decision 3).
  """
  @type seq :: non_neg_integer()

  @typedoc """
  The public door an input entered by (`t:StatifierPersistence.Executions.entry/0`),
  as a string.
  """
  @type door :: String.t()

  @typedoc """
  One stored input (ADR-0010 decision 2): the execution it belongs to, its
  ordinal, the door it entered by, and the opaque `input_blob` the facade
  encoded above this layer. A `nil` `input_blob` is the closed marker of
  decision 6 and nothing else.

  `append_input/3` is handed a record whose `seq` it must ignore - the
  adapter assigns the ordinal, because denseness is a property only the
  store can compute atomically - and returns the value it assigned.
  `list_inputs/2` returns records whose `seq` is authoritative.
  """
  @type input_record :: %{
          execution_id: execution_id(),
          seq: seq(),
          door: door(),
          input_blob: binary() | nil
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
  and `:execution_not_found` are the not-found arms every adapter must return
  instead of `nil` or a raise; `:execution_exists` is `insert_execution/2`'s refusal of
  a duplicate `execution_id`; `:metadata_unsupported` is the refusal-at-open arm
  for a non-empty `metadata` map an adapter cannot store (ADR-0006
  decision 3); `:execution_outcome_unsupported` and `:execution_states_unsupported`
  are the refusal-at-open arms for an adapter that cannot store an execution's
  `outcome_blob` or cannot answer the indexed status projection, which
  together are what a fan-out's settlement needs;
  `:content_hash_query_unsupported` is the same refusal for an adapter that
  cannot answer the drained query of ADR-0012 decision 3;
  `:chart_retirement_unsupported` is the refusal-at-open arm for a store
  whose `charts` row cannot be tombstoned at all - the two blob columns
  are still `NOT NULL`, or the two tombstone columns are absent - which
  is a backend limit named as a refusal rather than surfaced as a
  database error; `{:pinned, counts}` is what a retirement answers when
  anything in ADR-0012 decision 1's blocking set is non-zero, carrying
  every count it knows; `{:chart_retired, info}` is what both chart doors
  answer on a tombstoned hash, carrying who retired it and when
  (ADR-0012 decision 6) - never `:chart_not_found`, which keeps its
  meaning exactly: never stored, as against stored and retired;
  `:input_log_full` is
  `append_input/3`'s refusal past the host-declared cap, after the log has
  closed itself with a marker (ADR-0010 decision 6) - it refuses the
  append and never the step; `{:adapter, term()}` carries a backend
  failure (a database down, a timeout) that is not this layer's to
  interpret further.
  """
  @type error ::
          :chart_not_found
          | :position_not_found
          | :execution_exists
          | :execution_not_found
          | :metadata_unsupported
          | :execution_outcome_unsupported
          | :execution_states_unsupported
          | :content_hash_query_unsupported
          | :chart_retirement_unsupported
          | {:pinned, pin_counts()}
          | {:chart_retired, retired_info()}
          | :input_log_full
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

  A hash this adapter has tombstoned is the one save it refuses:
  `{:error, {:chart_retired, info}}`, and the row is not revived
  (ADR-0012 decision 6). A content-addressed save looks identical to an
  ordinary idempotent re-save, so it is the one call with no way to
  express "yes, I mean to undo that"; the retired arm is answered first,
  before the idempotency above applies.
  """
  @callback save_chart(opts(), StatifierPersistence.Storage.Adapter.chart_record()) ::
              :ok | {:error, error()}

  @doc """
  Fetches the chart stored under `content_hash`.

  Returns `{:error, :chart_not_found}` when no chart is stored under that
  hash - never `{:ok, nil}` and never a raise. The returned `chart_blob` and
  `identity_blob` must be byte-identical to what `save_chart/2` was given;
  an adapter must not normalize, truncate, or re-encode them.

  A tombstoned hash answers `{:error, {:chart_retired, info}}` instead,
  carrying who retired it and when (ADR-0012 decision 6), and the arm is
  answered first: the byte-identity obligation above is a statement
  about a chart the adapter holds, and a tombstoned row is not one. No
  call returns a chart record whose blobs are `nil`.
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
  Inserts `execution_record`, refusing a duplicate `execution_id` with
  `{:error, :execution_exists}`.

  The refusal must be atomic with the write: no interleaving of two
  `insert_execution/2` calls for the same `execution_id` may let both return `:ok`.
  Create-exactly-once rests on this callback alone, without a lock, so a
  check-then-insert implemented as two separate operations does not satisfy
  the contract - a SQL adapter reaches for a unique index (or equivalent
  backend-native uniqueness) and maps its violation to
  `{:error, :execution_exists}`.

  This callback does not decode `position_blob` or `identity_blob`, does
  not validate the status, and performs no identity check - the facade and
  the lifecycle own those (ADR-0003 decisions 1 and 2, ADR-0004
  decision 1).

  `metadata` is stored as given and read back by `fetch_execution/2` unchanged
  (ADR-0006 decision 1). Insert is the only write that sets it: the map is
  not mutable after create, and `update_execution/2` says so. An adapter reaching
  this callback has already declared `supports_metadata?/1` true for a
  non-empty map - the facade refuses at open otherwise - but an adapter
  whose backend cannot hold a particular value (a `jsonb` column and a
  tuple, say) refuses that value here with
  `{:error, :metadata_unsupported}` rather than storing something else.
  """
  @callback insert_execution(opts(), StatifierPersistence.Storage.Adapter.execution_record()) ::
              :ok | {:error, error()}

  @doc """
  Fetches the execution stored under `execution_id`.

  Returns `{:error, :execution_not_found}` when no execution is stored under that id -
  never `{:ok, nil}` and never a raise. The returned `identity_blob` and
  `position_blob` must be byte-identical to what was stored (a stored `nil`
  `position_blob` comes back as `nil`); an adapter must not normalize,
  truncate, or re-encode them, and it does not decode them either (ADR-0003
  decision 1). The returned `metadata` is the map `insert_execution/2` stored,
  unchanged, and `%{}` when none was stored - never `nil`.
  """
  @callback fetch_execution(opts(), execution_id()) ::
              {:ok, StatifierPersistence.Storage.Adapter.execution_record()} | {:error, error()}

  @doc """
  Overwrites the execution stored under `execution_record`'s `execution_id` with the full
  record.

  Returns `{:error, :execution_not_found}` when no execution exists for the id. This is
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

  `outcome_blob` is the second exception, and a narrower one: a record
  whose `outcome_blob` is `nil` leaves the stored value untouched, and a
  record carrying a binary sets it. The payload is written once, when the
  execution reaches a terminal status, and never cleared, so "nil means
  unchanged" is total rather than a partial-update surface - there is no
  writer that needs to set it back to `nil`. Without the carry-forward
  every ordinary step of an execution that had already answered would erase its
  answer, since this callback is a full-record overwrite and the stepper
  builds its record from a `MachineState` that has never seen one.

  `ended_at` is the third exception, and the one that is first-write-wins
  rather than nil-means-unchanged alone: a stored stamp is kept whatever
  the given record carries, and a row with no stamp takes the given
  record's `ended_at`, `nil` included. That is the rule that makes the
  stamp the time of the first terminal write the row took while it had
  none - a later overwrite of a stamped row, with the same status or
  another, cannot move it or clear it. The shared conformance suite pins
  both halves.

  Like the other execution callbacks it decodes nothing,
  validates no status transition, and performs no identity check - the
  facade and the lifecycle own those (ADR-0003 decisions 1 and 2, ADR-0004
  decision 1).
  """
  @callback update_execution(opts(), StatifierPersistence.Storage.Adapter.execution_record()) ::
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
  Optional per-execution lock (ADR-0003 amendment, 2026-08-22; ADR-0004
  decision 5).

  Provides mutual exclusion per `execution_id`: while one `lock_execution/3` call for a
  given `execution_id` is running `fun`, no other `lock_execution/3` call for the same
  `execution_id` may run its own. `fun` runs while the exclusion is held, and the
  exclusion is released on ANY exit from `fun` - a normal return, a throw,
  and a raise escaping `fun` alike. The lock must not leak: a raising `fun`
  propagates to the caller, but the next `lock_execution/3` for that `execution_id`
  must still acquire.

  This is the callback the default serialization strategy
  (`StatifierPersistence.Serialization.AdapterLock`) delegates to; an
  adapter that does not export it makes that strategy refuse with
  `{:error, {:serialization, :not_supported}}`. The Ecto adapter
  implements it as a transaction-scoped advisory lock plus a
  `SELECT ... FOR UPDATE` row lock inside a transaction that spans `fun`
  (ADR-0004 decision 5 as amended 2026-08-22) - the advisory half exists
  because a row lock alone excludes nothing for a `execution_id` whose execution has
  not been inserted yet.
  """
  @callback lock_execution(opts(), execution_id(), (-> result)) ::
              {:ok, result} | {:error, error()}
            when result: var

  @doc """
  Optional declaration that this adapter can store an execution's `metadata` map
  (ADR-0006 decision 3).

  Exporting it and returning `true` is how an adapter opts into the
  metadata contract - the same `@optional_callbacks` plus
  `function_exported?/3` shape `isolate/1` and `lock_execution/3` use. An adapter
  that does not export it stores no metadata, and
  `StatifierPersistence.Storage.insert_execution/5` refuses a non-empty map for
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

  Lists the executions whose stored `metadata` contains every key/value pair in
  `metadata`, recursively for a nested map. Equality match on all pairs is
  the whole query surface - no ranges, no partial matches, no ordering
  guarantee - the same contract `StatifierPersistence.Storage.Ecto`'s
  module-local function already documents. Exporting it is how an adapter
  declares it can answer "which executions name me as their parent", which is
  what a cascading cancel walks; an adapter that does not export it cannot
  host a durable subchart, and `StatifierPersistence.Driver` refuses at
  open rather than starting a child it could never cancel.
  """
  @callback list_executions_by_metadata(opts(), metadata()) ::
              {:ok, [StatifierPersistence.Storage.Adapter.execution_record()]} | {:error, error()}

  @doc """
  Optional declaration that this adapter can store an execution's `outcome_blob`
  (sp-t57, ruling C3).

  The same opt-in-by-export shape `supports_metadata?/1` uses. An adapter
  that does not export it, or answers `false`, stores no outcome payload,
  and `StatifierPersistence.Driver.start_child_at/6` refuses to start a
  fan-out child on it at open with `{:refused, :execution_outcome_unsupported}` -
  a child whose answer could never be read back is a child whose
  invocation could never be settled, the same posture
  `:child_listing_unsupported` already takes for a child that could never
  be cancelled.

  Nothing else refuses on it. An ordinary execution and a single-child durable
  subchart need no outcome payload, so an adapter written before this
  callback existed is conformant unchanged and sees no behaviour change.
  """
  @callback supports_execution_outcome?(opts()) :: boolean()

  @doc """
  Optional indexed status projection over a metadata match (sp-t57,
  ruling C5).

  Answers the same match `list_executions_by_metadata/2` answers - equality on
  every pair, recursively for a nested map - and returns
  `t:execution_state/0` rows instead of whole records: the execution id, its status,
  and its `child_index`.

  It exists because the settlement of a fan-out asks "have all N of this
  invocation's children reached a terminal status?" once per child, and
  answering that with the listing would move N identity and position
  blobs N times over one fan-out. An adapter implements this as a
  projection its backend can serve from an index (the Ecto adapter selects
  three columns under the `jsonb` containment predicate V03 indexes);
  materialising records and mapping them down is a conformant but
  pointless implementation, and defeats the callback's whole purpose.

  Exporting it is how an adapter declares it can answer the question.
  `StatifierPersistence.Driver.start_child_at/6` refuses at open with
  `{:refused, :execution_states_unsupported}` for an adapter that does not.
  """
  @callback list_execution_states_by_metadata(opts(), metadata()) ::
              {:ok, [StatifierPersistence.Storage.Adapter.execution_state()]} | {:error, error()}

  @doc """
  Optional declaration that this adapter can answer the drained query
  (ADR-0012 decision 3).

  The same opt-in-by-export shape `supports_metadata?/1` uses: an adapter
  exports it and answers `true`, the facade checks with
  `function_exported?/3`, and an adapter that does not export it stores
  everything it stored before and sees no behaviour change.

  `StatifierPersistence.Storage.count_executions_by_content_hash/2`
  answers `{:error, :content_hash_query_unsupported}` for such an adapter
  without calling it. The refusal matters beyond the query itself: a chart
  cannot be retired against a store that cannot count what is running on
  it, so the retirement refuses at open rather than acting on a count it
  could not take.

  The predicate covers `c:list_active_execution_ids_by_content_hash/2`
  as well: both read the same column under the same index, and a second
  opt-in for the second of them would be a capability a host has no way
  to want separately.
  """
  @callback supports_content_hash_query?(opts()) :: boolean()

  @doc """
  Optional count of the executions on one content hash, per stored arm
  (ADR-0012 decision 3).

  Answers `t:execution_counts/0` for `content_hash`: how many execution
  rows carry that hash in each of `:active`, `:needs_migration`,
  `:completed`, `:failed` and `:cancelled`, plus the `children` pin
  count. Every key is present for
  every hash, including one this store has never seen, which answers
  zeros.

  This is a count, not a listing: an adapter serves it from its backend as
  an aggregate and does not materialise the rows. Counting by loading
  every execution on the hash and folding it in Elixir is conformant and
  defeats the callback's whole purpose, which is to answer "what is
  running on this chart" on a store whose executions table is large.

  A chart is retired against this count (ADR-0012 decision 5), so an
  adapter that cannot answer it declines the whole capability by not
  exporting `supports_content_hash_query?/1` rather than answering a
  partial map.

  `children` is not a count of rows on the hash. It counts the durable
  children pinned to it: a linkage pin under this package's reserved
  metadata key naming `content_hash`, whose parent execution is in the
  `:active` or the `:needs_migration` arm, whatever arm the child itself
  is in (ADR-0012 decision 1, as ADR-0014 decision 4 reads it). An
  adapter that holds no metadata holds no pin and counts zero.
  """
  @callback count_executions_by_content_hash(opts(), content_hash()) ::
              {:ok, StatifierPersistence.Storage.Adapter.execution_counts()}
              | {:error, error()}

  @doc """
  Optional listing of the ids of the `:active` executions on one content
  hash (ADR-0012 decision 4).

  Part of `supports_content_hash_query?/1`'s capability rather than a
  capability of its own: an adapter that declares that predicate exports
  this too, and one that does not export the predicate is not asked.

  It exists because decision 4 hands a pin source `:execution_ids` in its
  context - a source such as a timer queue knows executions and never
  knows hashes, so the ids are what let it answer without learning this
  package's key - and decision 3's query answers counts, which a source
  cannot be handed. Only the `:active` arm is listed: a terminal
  execution pins nothing (decision 1), and a source asked about one
  would be asked about work that cannot resume. A `:needs_migration`
  execution is not listed either (ADR-0014 decision 4): it already
  refuses a retirement through its own count, so a source's view of it
  could not change whether one proceeds.

  A hash this store has never seen answers `{:ok, []}`, not a not-found
  arm, for the reason the counts answer zeros.
  """
  @callback list_active_execution_ids_by_content_hash(opts(), content_hash()) ::
              {:ok, [execution_id()]} | {:error, error()}

  @doc """
  Optional declaration that this adapter can tombstone a chart row
  (ADR-0012 decision 6).

  The same opt-in-by-export shape `supports_metadata?/1` uses, with one
  difference worth stating: this predicate is about the **store**, not
  about the adapter's code. Migration V07 makes `charts.identity_blob`
  and `charts.chart_blob` nullable and adds `retired_at` and
  `retired_by`, and V07's two `modify/3` calls are guarded to Postgres
  because `ecto_sqlite3` raises from `modify/3`. So the very same
  adapter module answers `true` against one store and `false` against
  another, and an adapter answers by asking the store it is pointed at
  rather than by asking what backend it is.

  Nulling a chart's bytes against a store whose blob columns are still
  `NOT NULL` is a constraint violation, and a database error is the
  wrong answer to "may I retire this": it reads as a defect rather than
  as the backend limit it is. So
  `StatifierPersistence.Storage.retire_chart/3` refuses at open with
  `{:error, :chart_retirement_unsupported}` for such a store, before it
  counts anything and before it opens a transaction.
  """
  @callback supports_chart_retirement?(opts()) :: boolean()

  @doc """
  Optional retirement of one chart (ADR-0012 decisions 5 and 6): the
  counts and the tombstone, as one atomic unit.

  The unit is the contract. An adapter takes decision 1's counts and
  writes the tombstone so that nothing can appear between the two - one
  transaction on a database, one atomic state transition on an adapter
  without one - because a pin that appears between a count and a write
  is exactly the chart this record exists to keep from being retired out
  from under.

  Inside that unit, in this order:

  - no row on the hash: `{:error, :chart_not_found}`, and nothing is
    written;
  - a row already carrying a `retired_at`: `{:error, {:chart_retired,
    info}}`, and nothing is written - a second retirement is the retired
    arm, never a second tombstone;
  - otherwise the counts: the `:active` and `:needs_migration` execution
    rows on the hash, the durable-child linkage pins naming it whose
    parent is `:active` or `:needs_migration`, and the position rows on
    it, folded with the `sources` counts `retirement` carries into a
    `t:pin_counts/0`. If any blocking count is non-zero,
    `{:error, {:pinned, counts}}` and
    **nothing is written**; the three terminal arms are reported in that
    map and never cause it.
  - all clear: `retired_at` and `retired_by` are set from
    `retirement`, `identity_blob` and `chart_blob` are nulled, and the
    row and its content hash are kept. `{:ok, info}`.

  The row and the hash surviving is the point: the removal is the bytes,
  and what is left is a hash that answers for its own retirement on both
  chart doors.
  """
  @callback retire_chart(opts(), content_hash(), retirement()) ::
              {:ok, retired_info()} | {:error, error()}

  @doc """
  Optional declaration that this adapter can read one hash's tombstone
  without reading the chart's bytes (ADR-0012 decision 6).

  The same opt-in-by-export shape `supports_metadata?/1` uses: an adapter
  exports it and answers `true`, the facade checks with
  `function_exported?/3`, and an adapter that does not export it sees no
  behaviour change. It is a predicate of its own rather than a widening of
  `supports_chart_retirement?/1`, because an adapter that declared that
  predicate before this one existed would otherwise be called for a
  callback it never agreed to export.

  It is independent of `supports_chart_retirement?/1` in the other
  direction too: a store that can never carry a tombstone can still answer
  "this hash has none" cheaply, and that is the answer every create on
  such a store needs.

  For an adapter that does not declare it,
  `StatifierPersistence.Storage.check_chart_retired/2` falls back to
  `c:fetch_chart/2` and reads the retired arm off the full row, which
  answers the same thing at the cost of transferring the chart's bytes.
  """
  @callback supports_retired_info?(opts()) :: boolean()

  @doc """
  Optional read of one hash's tombstone, without reading `identity_blob`
  or `chart_blob` (ADR-0012 decision 6).

  Answers `{:ok, info}` for a tombstoned hash, carrying the same
  `t:retired_info/0` the retired arm of `c:fetch_chart/2` carries, and
  `{:ok, nil}` for every hash that has no tombstone - a stored chart that
  was never retired and a hash this store never held alike. Telling
  those two apart is `c:fetch_chart/2`'s job, and this callback exists
  for a caller that needs only the one question answered: whether the
  hash is retired.

  The bytes not crossing is the contract. An adapter answering this by
  loading the whole chart row and discarding the blobs is conformant in
  what it returns and defeats the callback's whole purpose, which is that
  a create's tombstone check costs the same whatever the chart's size.
  """
  @callback fetch_retired_info(opts(), content_hash()) ::
              {:ok, retired_info() | nil} | {:error, error()}

  @doc """
  Optional declaration that this adapter can write a tree migration as one
  unit (ADR-0015 decision 3).

  The same opt-in-by-export shape `c:supports_chart_retirement?/1` uses:
  an adapter exports it and answers `true`, and
  `StatifierPersistence.Executions.migrate_tree/4` refuses at open with
  `{:error, :tree_migration_unsupported}` for an adapter that does not,
  before any read and before any write. An adapter that does not export
  it sees no other change.
  """
  @callback supports_tree_migration?(opts()) :: boolean()

  @doc """
  Optional write of a tree migration: every write in `writes`, or none of
  them (ADR-0015 decision 3).

  The unit is the contract, the one `c:retire_chart/3` already asks for:
  one transaction on a database, one atomic state transition on an adapter
  without one. `:ok` means every write in the list landed; `{:error,
  reason}` means none of them did. An execution the list names that is
  not stored is `{:error, :execution_not_found}`, and nothing is written.

  Each write is a `t:tree_write/0`. A re-pin overwrites the status, the
  content hash, the identity blob, the position blob and the failure,
  rewrites the linkage pin's `content_hash` when the write carries one and
  the stored metadata holds a linkage, and carries every other metadata
  key, the `outcome_blob` and the stored `ended_at` forward verbatim. A
  park writes the status and the failure alone.

  An adapter reached inside an enclosing transaction - the Ecto adapter's
  `c:lock_execution/3` is one - never returns an error that would commit
  the writes it had already made. A refusal it can decide before its
  first write, such as an execution that is not stored, it returns as it
  is: nothing was written, so the enclosing transaction is left open and
  the caller sees the adapter's own reason. A failure after a write
  rolls the enclosing transaction back. Like the other execution
  callbacks it decodes nothing, validates no status transition and
  performs no identity check.
  """
  @callback write_tree_migration(opts(), [tree_write()]) :: :ok | {:error, error()}

  @doc """
  Optional declaration that this adapter keeps an execution's input log
  (ADR-0010 decision 1).

  The same opt-in-by-export shape `supports_metadata?/1` and
  `supports_execution_outcome?/1` use: an adapter exports it and answers `true`,
  the facade checks with `function_exported?/3`, and an adapter that does
  not export it stores no inputs and sees no behaviour change.
  `StatifierPersistence.Storage.InMemory` and every adapter written before
  ADR-0010 stay conformant without a line of change.

  **No execution-lifecycle call refuses on it**, and that is the deliberate
  departure from `supports_metadata?/1`'s refusal at open. Those refuse
  because something the host *asked for* would otherwise be silently
  dropped; the input log is a derived record of inputs the host is
  supplying anyway, and refusing to run a chart because the log cannot be
  kept would let a diagnostic facility break the execution it is diagnosing. A
  host that needs to know asks
  `StatifierPersistence.Storage.input_log_supported?/1`.
  """
  @callback supports_input_log?(opts()) :: boolean()

  @doc """
  Optional append of one input to `execution_id`'s log (ADR-0010 decision 2).

  The adapter assigns the ordinal and returns it: the `seq` on the given
  record is ignored on the way in and authoritative on the way out,
  because denseness from zero is a property only the store can compute
  atomically. A lost race must fail the write rather than duplicate an
  ordinal - a gap in a log is a defect, not a reading.

  `input_blob` is opaque here in `position_blob`'s strong sense: the
  facade above every adapter encodes the `%Statifier.Event{}` the
  interpreter saw (ADR-0010 decision 3), and nothing in this layer decodes
  it, inspects it, or says what produced it. `execution_id`, `seq` and `door`
  are identity and lookup values and are stored beside it, not inside it.

  Past the cap the host declared at `init/1` (`input_log_cap:`), the
  append returns `{:error, :input_log_full}` and the log is **closed**:
  the cap's last slot is written as a record with a `nil` `input_blob`,
  and no later append to that execution ever succeeds (ADR-0010 decision 6). A
  truncated log that looks complete is worse than no log, so the
  truncation is a value in the log rather than an absence.
  """
  @callback append_input(opts(), execution_id(), input_record()) ::
              {:ok, seq()} | {:error, error()}

  @doc """
  Optional listing of `execution_id`'s whole input log, in ascending `seq`
  (ADR-0010 decision 2).

  The whole log, always - no filter, no range, no limit, no reverse. The
  whole log is what a replay consumes, and the cap is what bounds it. A
  execution with no inputs is `{:ok, []}`; an execution that does not exist is
  `{:error, :execution_not_found}`, the not-found arm this layer already
  requires instead of `nil` or a raise.
  """
  @callback list_inputs(opts(), execution_id()) ::
              {:ok, [input_record()]} | {:error, error()}

  @optional_callbacks isolate: 1,
                      lock_execution: 3,
                      supports_metadata?: 1,
                      list_executions_by_metadata: 2,
                      supports_execution_outcome?: 1,
                      list_execution_states_by_metadata: 2,
                      supports_content_hash_query?: 1,
                      count_executions_by_content_hash: 2,
                      list_active_execution_ids_by_content_hash: 2,
                      supports_chart_retirement?: 1,
                      retire_chart: 3,
                      supports_retired_info?: 1,
                      fetch_retired_info: 2,
                      supports_tree_migration?: 1,
                      write_tree_migration: 2,
                      supports_input_log?: 1,
                      append_input: 3,
                      list_inputs: 2

  @doc """
  Folds one hash's counts into the shape a refusal carries
  (`t:pin_counts/0`).

  Every adapter that implements `c:retire_chart/3` builds its refusal
  through this function, so the two adapters cannot drift into two
  shapes for one answer. `counts` is the drained query's own six-key
  map, which both adapters already compute.
  """
  @spec pin_counts(execution_counts(), non_neg_integer(), source_counts()) :: pin_counts()
  def pin_counts(%{} = counts, positions, %{} = sources) when is_integer(positions) do
    %{
      executions: Map.take(counts, [:active, :needs_migration, :completed, :failed, :cancelled]),
      children: counts.children,
      positions: positions,
      sources: sources
    }
  end

  @doc """
  Whether `counts` holds a pin that refuses a retirement: ADR-0012
  decision 1's blocking set, and nothing else.

  A non-zero `executions.active` or `executions.needs_migration` (a
  parked execution pins its chart, ADR-0014 decision 4), a non-zero
  `children`, a non-zero `positions`, or a non-zero count under any
  source. The three terminal
  execution arms are reported in `counts` and are not read here, which
  is what keeps a chart retirable after everything on it has finished.

  One function so that the blocking set is one list rather than one per
  adapter: an adapter answers what it counted, and this answers whether
  what it counted is a pin.
  """
  @spec pinned?(pin_counts()) :: boolean()
  def pinned?(%{executions: executions, children: children, positions: positions} = counts) do
    executions.active > 0 or executions.needs_migration > 0 or children > 0 or positions > 0 or
      sources_pinned?(counts.sources)
  end

  @doc """
  Whether any registered source reported a non-zero count: the one
  member of ADR-0012 decision 1's blocking set that is not a row in
  this package's tables.

  Separate from `pinned?/1` because an adapter whose atomic unit is a
  database statement guards its own three pin kinds inside that
  statement and cannot guard this one there - a source's counts were
  taken outside the database and arrive as data.
  """
  @spec sources_pinned?(source_counts()) :: boolean()
  def sources_pinned?(sources) do
    Enum.any?(sources, fn {_source, named} ->
      Enum.any?(named, fn {_name, count} -> count > 0 end)
    end)
  end
end
