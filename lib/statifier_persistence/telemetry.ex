defmodule StatifierPersistence.Telemetry do
  @moduledoc """
  The `:telemetry` surface for this package's storage-phase seams
  (ADR-0009) - the single definition site for every
  `[:statifier_persistence, ...]` event name, and the one module in `lib/`
  that calls `:telemetry.execute/3`.

  `docs/telemetry.md` is the full contract: what each event answers, what
  it deliberately leaves to statifier-ex and to `opentelemetry_ecto`, and
  what `opentelemetry_statifier` does with it. This moduledoc is the
  reference table; that note is the reasoning.

  `events/0` returns every name below, built from the same literal-atom
  lists the emitters use, so the bridge can attach one handler per event
  name without hand-copying the list (ADR-0009 decision 8,
  `ots-ADR-0003`).

  This module owns *family two* only. The interpreter's own family -
  `[:statifier, :session, ...]` with `driver: :persistence` - is emitted
  by calling `Statifier.Telemetry` directly from the stepper seam and is
  deliberately not wrapped here: a wrapper would be the second
  implementation `st-ADR-0067` decision 2 exists to prevent.

  ## Structural rules (ADR-0009 decisions 3, 5, 8, 9)

  - **The prefix is `[:statifier_persistence, ...]`, fixed and not
    configurable.** The bridge must name the events at compile time, and a
    per-host prefix would make its attach list depend on host
    configuration it cannot see.
  - **Measurements are numbers; metadata is everything else**, integer
    indexes included - `child_index` is metadata, because an opaque index
    has no numeric meaning to average.
  - **Two spans: the step seam and the batch migration.** This package
    owns an interval nobody else measures - lock, load, decode,
    identity-check, advance, execute effects, persist - and the upstream
    macrostep span nests inside it. A batch migration is the second
    (ADR-0017 decision 6): one call over every execution on a chart hash.
    Each opens with `:start` and closes with exactly one of `:stop` or
    `:exception`. `span_ref` is a fresh `make_ref/0` per span, carried on
    both halves, and is the only pairing key (`st-ADR-0040` decision 2).
    Everything else is a single point-in-time event.
  - **`execution_id` is the identity key**, never `scope`; `session_id` rides
    only where a position has already been decoded and is explicitly `nil`
    otherwise.
  - **Emission is unconditional.** There is no config knob and no sampling
    knob: `:telemetry.execute/3` on an event with no handlers is a lookup
    and a return.
  - **Amendment discipline.** Adding a measurement or a metadata key to an
    existing event is an amendment and is fine; renaming or removing one,
    renaming an event, or changing the `:persistence` driver atom is
    breaking and needs a new ADR.

  ## The step seam

  Brackets one serialized drive - `create/4`, `step/5`, `fail/4` or
  `cancel/3` inside `StatifierPersistence.Executions`'s own `serialized/5`.
  Emitted on the calling process. The
  `[:statifier, :session, :macrostep, ...]` span opens and closes inside
  it.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :execution, :step, :start]` | `system_time`, `monotonic_time` | `execution_id`, `entry`, `span_ref` |
  | `[:statifier_persistence, :execution, :step, :stop]` | `duration`, `monotonic_time` | `execution_id`, `session_id`, `content_hash`, `entry`, `outcome`, `status`, `reason`, `span_ref`, `invoke_id`, `child_count`, `selection` |
  | `[:statifier_persistence, :execution, :step, :exception]` | `duration`, `monotonic_time` | `execution_id`, `entry`, `span_ref`, `kind`, `reason`, `stacktrace` |
  | `[:statifier_persistence, :execution, :step, :reentered]` | `system_time` | `execution_id`, `session_id`, `content_hash`, `name`, `origin`, `opts` |
  | `[:statifier_persistence, :execution, :lock]` | `duration`, `system_time` | `execution_id`, `strategy`, `outcome`, `reason` |

  `entry` is which public door was used: `:create`, `:step`,
  `:done_invocation`, `:failed_invocation`, `:answer_parent`, `:fail`,
  `:cancel`. `outcome` on the stop is `:ok`, `:discarded` or `:error`.
  `[:statifier_persistence, :execution, :lock]`'s `duration` is the **wait** for
  the per-execution exclusion, not the held time, and its `outcome` is
  `:acquired` or `:unavailable`. It is also emitted by
  `StatifierPersistence.Executions.unpark/3`, which takes the same exclusion
  and opens no step span.

  `invoke_id` and `child_count` on the stop are `nil` on every ordinary
  drive and set on the `entry: :answer_parent` step a child takes on its
  parent's behalf, so the step span carrying a fan-out's whole assembled
  answer is recognisable as that one (the ADR-0009 sp-8wv amendment).
  `child_count` is `nil` for a single-child subchart.

  `selection` on the stop says whether the event the step delivered
  selected a transition: `:selected` when it selected at least one and
  `:none` when it selected none, whether or not the position was created
  with `trace: true`. It is read off the returned position's
  `t:Statifier.MachineState.last_selection/0`, so it is set on every
  `:ok` step whose event ran an external round - `:step`,
  `:done_invocation`, `:failed_invocation` and `:answer_parent` - and
  `nil` on a `:create`, `:fail` or `:cancel` stop, which delivers no
  event, and on every `:discarded` or `:error` stop. `:none` does not say
  why: an event no transition names and one whose every guard was false
  read the same (the ADR-0009 sp-qrkx amendment).

  `:exception` closes the span in place of `:stop` when anything inside
  the drive raises, throws or exits - a host executor, an event builder,
  an adapter or the serialization strategy - and the raise then reaches
  the caller unchanged, with its original stacktrace. Its keys are the
  ones `:telemetry.span/3` puts on its own `:exception` event: the start
  half's metadata plus `kind`, `reason` and `stacktrace`. The raised term
  and its stacktrace can carry any value the failing code held - an event
  builder's is the decoded machine state, datamodel included - so both are
  narrowed before the event is emitted. `reason` is the exception's module
  for an `:error` (a raw Erlang error is normalized first, so a failed match
  reports `MatchError`), and for a `:throw` or `:exit` the thrown or exit
  atom, or `:redacted` for any other term. `stacktrace` keeps each frame's
  module and function, replaces an argument list by its arity, and keeps
  only `:file` and `:line` of the location. The caller's re-raise keeps
  the original reason and stacktrace.

  `:reentered` is a point-in-time event inside the span: one per
  `error.communication` event the persist tail re-entered into the chart
  after an executor failure (ADR-0004 decision 4), emitted on the calling
  process after that re-entry was delivered and before the step's `:stop`,
  in delivery order. `name` is `"error.communication"`, `origin` is the
  `t:Statifier.Event.Cause.origin/0` tuple the event was raised with, and
  `opts` is the keyword list it was raised with (`[sendid: id]` for a
  failed `<send>`, `[]` otherwise). A host that folds the events it
  delivered to rebuild a position folds each of these after the event of
  the step that produced it, through
  `Statifier.Interpreter.deliver_internal(machine_state, :platform, name,
  origin, opts)`, and reaches the persisted position. A failure whose
  re-entry was not delivered emits none. The event carries no `span_ref`:
  it pairs with its step by `execution_id` and by arriving between that
  step's `:start` and `:stop`.

  ## The storage seam

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :adapter, :call]` | `duration`, `system_time` | `adapter`, `callback`, `outcome`, `reason`, `execution_id`, `session_id`, `content_hash` |
  | `[:statifier_persistence, :identity, :refused]` | `system_time` | `execution_id`, `session_id`, `stage`, `reason`, `stored_content_hash`, `supplied_content_hash` |

  `callback` is the `StatifierPersistence.Storage.Adapter` callback name, a
  closed vocabulary fixed by the behaviour. `stage` on a refusal is
  `:position`, `:execution` or `:chart`, and `reason` is `:identity_mismatch` or
  `:unidentified_chart`; **only the two content hashes travel**, never the
  `Statifier.Machine.Identity` structs the error term carries.

  ## The execution lifecycle seam

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :execution, :created]` | `system_time` | `execution_id`, `session_id`, `content_hash`, `child?`, `metadata?` |
  | `[:statifier_persistence, :execution, :terminated]` | `system_time` | `execution_id`, `session_id`, `content_hash`, `status`, `driven_by`, `reason` |
  | `[:statifier_persistence, :execution, :discarded]` | `system_time` | `execution_id`, `entry`, `reason`, `repaired?` |
  | `[:statifier_persistence, :execution, :migrated]` | `system_time` | `execution_id`, `from_content_hash`, `to_content_hash`, `dropped` |
  | `[:statifier_persistence, :execution, :unparked]` | `system_time` | `execution_id`, `content_hash` |
  | `[:statifier_persistence, :effect, :failed]` | `system_time` | `execution_id`, `session_id`, `content_hash`, `kind`, `executor`, `reason`, `reentered?` |
  | `[:statifier_persistence, :drive, :turns_exhausted]` | `system_time`, `turns` | `execution_id`, `entry` |

  `driven_by` on `:terminated` is `:chart` or `:host` - `fail/4` and
  `cancel/3` are the `:host` ones, and upstream emits nothing at all for
  them. `:discarded`'s `reason` is the closed vocabulary `:terminal_execution`,
  `:builder_declined`, `:position_terminal`, and only the third sets
  `repaired?: true`.

  `:migrated` fires once per successful
  `StatifierPersistence.Executions.migrate/4`, after its serialization
  section returns (ADR-0013 decision 5). It carries both content hashes
  under their own names, because a migration has two charts in hand, and
  `dropped` is the list of dropped state ids that were in the execution's
  configuration. A refused or parked migration emits nothing.

  `:unparked` fires once per `StatifierPersistence.Executions.unpark/3`
  that writes a `:needs_migration` execution back to `:active`, after its
  serialization section returns. `content_hash` is the chart the execution
  was parked on and goes on under. An unpark that writes nothing - of an
  `:active` execution, of a terminal one, or one refused - emits no
  `:unparked`.

  ## The batch migration span (ADR-0017 decision 6)

  Brackets one `StatifierPersistence.Executions.migrate_batch/3` call,
  opened once its options are checked. Emitted on the calling process.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :execution, :migrate_batch, :start]` | `system_time`, `monotonic_time` | `from`, `to`, `dry_run`, `span_ref` |
  | `[:statifier_persistence, :execution, :migrate_batch, :stop]` | `duration`, `monotonic_time`, one count per outcome of the mode | `from`, `to`, `dry_run`, `span_ref`, `outcome`, `reason` |
  | `[:statifier_persistence, :execution, :migrate_batch, :exception]` | `duration`, `monotonic_time` | `from`, `to`, `dry_run`, `span_ref`, `kind`, `reason`, `stacktrace` |

  `from` and `to` are the plan's two content hashes. The stop's counts are
  the report's `counts`: `would_migrate`, `would_refuse` and `skipped`
  under the dry run; `migrated`, `refused`, `parked` and `skipped` under
  the apply. `outcome` is `:ok` or `:error`; on `:error` - a refusal of the
  whole batch - `reason` is that refusal and every count of the mode is
  `0`, and on `:ok` it is `nil`. The exception's `kind`, `reason` and
  `stacktrace` are narrowed as the step span's are. The dry run and a
  whole-batch refusal open the span; a malformed option raises before it
  opens. Each execution the apply moves still emits its own
  `[:statifier_persistence, :execution, :migrated]` inside the span, and
  the dry run emits none.

  ## The durable-subchart seam (ADR-0008)

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :child, :started]` | `system_time` | `parent_execution_id`, `child_execution_id`, `invoke_id`, `child_index`, `content_hash`, `session_id` |
  | `[:statifier_persistence, :child, :refused]` | `system_time` | `parent_execution_id`, `invoke_id`, `reason` |
  | `[:statifier_persistence, :child, :recorded]` | `system_time` | `parent_execution_id`, `child_execution_id`, `invoke_id`, `child_index`, `outcome` |
  | `[:statifier_persistence, :child, :answered]` | `system_time` | `child_execution_id`, `parent_execution_id`, `invoke_id`, `outcome`, `child_count`, `failed_count`, `delivery` |
  | `[:statifier_persistence, :child, :settled]` | `system_time`, `child_count`, `completed`, `failed`, `cancelled`, `unstarted` | `parent_execution_id`, `invoke_id`, `policy`, `decision` |
  | `[:statifier_persistence, :child, :cascade_cancelled]` | `system_time`, `count`, `retained` | `parent_execution_id`, `invoke_id` |

  `content_hash` on `:started` is the child's *pinned* hash (ADR-0008
  decision 2). `count` on `:cascade_cancelled` is how many executions the sweep
  actually cancelled and `retained` is how many it found already terminal
  and left alone; both are legitimately `0`.

  `:recorded` fires once per fan-out child answer written under the
  parent's exclusion, and `:settled` once per settlement decision -
  `decision` is `:answer` or `:not_yet` - both from the settlement section
  (the ADR-0009 sp-8wv amendment). `decision` is the settlement's, not the
  parent's: a parked parent that refuses the assembled answer still reports
  `:answer` on `:settled`, and what its door answered is the `delivery` of
  the `:answered` that follows. `:answered`'s `outcome` is the
  *invocation's* aggregate for a fan-out, `:failed` when any index failed,
  even though the parent's door is always `done_invocation/5`; and
  `child_count` and `failed_count` are `nil` on the single-child path,
  which is not an invocation with a width.

  `:answered`'s `delivery` is what the parent's door answered, a closed
  vocabulary: `:delivered`, `:discarded` (the parent had already left the
  invocation), `:needs_migration` (the parent is parked and refused the
  answer whole, ADR-0014 decision 2) or `:error` (any other error). The
  automatic answer returns the child's own result whatever the door
  answered, so `:needs_migration` here is how a host learns that an answer
  it must deliver again was refused. Two more values say the answer never
  reached a door: `:parent_unfetched` (the parent's own record did not
  fetch) and `:parent_chart_unresolved` (the driver's `chart_resolver:`
  did not return the parent's chart). On those two, `outcome` is the
  child's own and `failed_count` is `nil`, because no settlement ran.

  ## Cardinality and disclosure

  Every metadata key is bounded by the chart or by a closed vocabulary
  except `execution_id` (and `parent_execution_id` / `child_execution_id`), which is
  host-supplied and is a correlation id for a span or a log line, **never
  a metric dimension**, `reason`, which carries an arbitrary executor
  or adapter term on some events and must be narrowed before it becomes a
  dimension, and `opts` on `:reentered`, whose `sendid` is a `<send>`'s
  own id or one the interpreter generated for it: a value to fold, never
  a dimension.

  **Nothing host-opaque and nothing from the datamodel is ever on an
  event** (ADR-0009 decision 7): not the `chart_blob`, the
  `position_blob`, the `identity_blob`, the ADR-0006 `metadata` map, the
  datamodel, an invoke's `params`, or a `:done` effect's `donedata`.
  `metadata?` on `[:statifier_persistence, :execution, :created]` is a boolean -
  whether a non-empty host map was supplied - and that is the whole of
  what this contract says about it.
  """

  @typedoc "Any event name this module emits."
  @type event_name :: [atom(), ...]

  @typedoc """
  What a parent's door answered to a child's answer - the `delivery`
  metadata of `[:statifier_persistence, :child, :answered]`.
  `:parent_unfetched` and `:parent_chart_unresolved` are the two ways the
  automatic answer never reached the door at all.
  """
  @type delivery ::
          :delivered
          | :discarded
          | :needs_migration
          | :error
          | :parent_unfetched
          | :parent_chart_unresolved

  @typedoc """
  A field list for one event: every key the contract names for it, in any
  order. A key the caller omits is emitted as `nil` rather than dropped,
  so a handler never has to `Map.get/3` its way around a shape that
  varies.
  """
  @type fields :: keyword()

  @execution_step_start [:statifier_persistence, :execution, :step, :start]
  @execution_step_stop [:statifier_persistence, :execution, :step, :stop]
  @execution_step_exception [:statifier_persistence, :execution, :step, :exception]
  @execution_step_reentered [:statifier_persistence, :execution, :step, :reentered]
  @execution_lock [:statifier_persistence, :execution, :lock]
  @adapter_call [:statifier_persistence, :adapter, :call]
  @identity_refused [:statifier_persistence, :identity, :refused]
  @execution_created [:statifier_persistence, :execution, :created]
  @execution_terminated [:statifier_persistence, :execution, :terminated]
  @execution_discarded [:statifier_persistence, :execution, :discarded]
  @execution_migrated [:statifier_persistence, :execution, :migrated]
  @execution_unparked [:statifier_persistence, :execution, :unparked]
  @effect_failed [:statifier_persistence, :effect, :failed]
  @drive_turns_exhausted [:statifier_persistence, :drive, :turns_exhausted]
  @execution_migrate_batch_start [:statifier_persistence, :execution, :migrate_batch, :start]
  @execution_migrate_batch_stop [:statifier_persistence, :execution, :migrate_batch, :stop]
  @execution_migrate_batch_exception [
    :statifier_persistence,
    :execution,
    :migrate_batch,
    :exception
  ]
  @child_started [:statifier_persistence, :child, :started]
  @child_refused [:statifier_persistence, :child, :refused]
  @child_recorded [:statifier_persistence, :child, :recorded]
  @child_answered [:statifier_persistence, :child, :answered]
  @child_settled [:statifier_persistence, :child, :settled]
  @child_cascade_cancelled [:statifier_persistence, :child, :cascade_cancelled]

  @events [
    @execution_step_start,
    @execution_step_stop,
    @execution_step_exception,
    @execution_step_reentered,
    @execution_lock,
    @adapter_call,
    @identity_refused,
    @execution_created,
    @execution_terminated,
    @execution_discarded,
    @execution_migrated,
    @execution_unparked,
    @effect_failed,
    @drive_turns_exhausted,
    @execution_migrate_batch_start,
    @execution_migrate_batch_stop,
    @execution_migrate_batch_exception,
    @child_started,
    @child_refused,
    @child_recorded,
    @child_answered,
    @child_settled,
    @child_cascade_cancelled
  ]

  @doc """
  Every `[:statifier_persistence, ...]` event name this package emits, in
  the order `docs/telemetry.md` tables them.

  This is what a bridge attaches to: `ots-ADR-0003` attaches one handler
  per event name under its own handler id, and it cannot do that for a
  list it has to hand-copy.
  """
  @spec events() :: [event_name(), ...]
  def events, do: @events

  @doc """
  Emits `[:statifier_persistence, :execution, :step, :start]` and returns the
  `System.monotonic_time/0` reading `execution_step_stop/2` measures `duration`
  against.

  Returning the reading rather than taking one is deliberate: it is the
  same reading the `monotonic_time` measurement carries, so the span's
  `duration` and the two halves' `monotonic_time` values cannot drift
  apart.
  """
  @spec execution_step_start(execution_id :: term(), entry :: atom(), span_ref :: reference()) ::
          integer()
  def execution_step_start(execution_id, entry, span_ref) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_step_start,
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      %{execution_id: execution_id, entry: entry, span_ref: span_ref}
    )

    monotonic_time
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :step, :stop]`, `duration` in
  `:native` units measured from `execution_step_start/3`'s reading.
  """
  @spec execution_step_stop(start_time :: integer(), fields :: fields()) :: :ok
  def execution_step_stop(start_time, fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_step_stop,
      %{duration: monotonic_time - start_time, monotonic_time: monotonic_time},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        entry: fields[:entry],
        outcome: fields[:outcome],
        status: fields[:status],
        reason: fields[:reason],
        span_ref: fields[:span_ref],
        invoke_id: fields[:invoke_id],
        child_count: fields[:child_count],
        selection: fields[:selection]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :step, :exception]`, the
  step span's close when the drive raised, threw or exited, `duration` in
  `:native` units measured from `execution_step_start/3`'s reading.

  The caller re-raises afterwards; this function only reports. The keys
  follow `:telemetry.span/3`'s own `:exception` event; the values of
  `reason` and `stacktrace` are narrowed so no raised value, call argument
  or location detail travels on the event (see the step seam section
  above).
  """
  @spec execution_step_exception(start_time :: integer(), fields :: fields()) :: :ok
  def execution_step_exception(start_time, fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_step_exception,
      %{duration: monotonic_time - start_time, monotonic_time: monotonic_time},
      %{
        execution_id: fields[:execution_id],
        entry: fields[:entry],
        span_ref: fields[:span_ref],
        kind: fields[:kind],
        reason: narrow_reason(fields[:kind], fields[:reason], fields[:stacktrace]),
        stacktrace: narrow_stacktrace(fields[:stacktrace])
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :step, :reentered]` - one
  `error.communication` event the persist tail re-entered into the chart
  after an executor failure, emitted inside the step span that produced it
  so a handler receives them in delivery order.

  `name`, `origin` and `opts` are the three arguments the re-entry passed to
  `Statifier.Interpreter.deliver_internal/5` beside `:platform`, unchanged,
  so a host folding delivered events can pass them back to reproduce the
  persisted position.
  """
  @spec execution_step_reentered(fields :: fields()) :: :ok
  def execution_step_reentered(fields) do
    :telemetry.execute(
      @execution_step_reentered,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        name: fields[:name],
        origin: fields[:origin],
        opts: fields[:opts]
      }
    )
  end

  # The raised term can hold any value the failing code held, so only a
  # bounded name for it travels: the exception module for an error (after
  # normalizing a raw Erlang error), a bare atom for a throw or an exit,
  # and `:redacted` for anything else.
  @spec narrow_reason(atom(), term(), Exception.stacktrace() | nil) :: atom()
  defp narrow_reason(:error, reason, stacktrace) do
    %module{} = Exception.normalize(:error, reason, stacktrace || [])
    module
  end

  defp narrow_reason(_kind, reason, _stacktrace) when is_atom(reason), do: reason
  defp narrow_reason(_kind, _reason, _stacktrace), do: :redacted

  # A frame of a function-clause failure carries the call's arguments in
  # place of its arity, and a location can carry `:error_info` beside the
  # file and line; only the module, the function, the arity and the file
  # and line travel.
  @spec narrow_stacktrace(Exception.stacktrace() | nil) :: Exception.stacktrace() | nil
  defp narrow_stacktrace(nil), do: nil

  defp narrow_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, arity_or_arguments, location} ->
        {module, function, arity(arity_or_arguments), Keyword.take(location, [:file, :line])}

      _frame ->
        :redacted
    end)
  end

  defp arity(arguments) when is_list(arguments), do: length(arguments)
  defp arity(arity), do: arity

  @doc """
  Emits `[:statifier_persistence, :execution, :lock]`. `duration` is the wait
  for the per-execution exclusion in `:native` units, never the held time.
  """
  @spec execution_lock(duration :: integer(), fields :: fields()) :: :ok
  def execution_lock(duration, fields) do
    :telemetry.execute(
      @execution_lock,
      %{duration: duration, system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        strategy: fields[:strategy],
        outcome: fields[:outcome],
        reason: fields[:reason]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :adapter, :call]`, `duration` in
  `:native` units around one storage-adapter callback.
  """
  @spec adapter_call(duration :: integer(), fields :: fields()) :: :ok
  def adapter_call(duration, fields) do
    :telemetry.execute(
      @adapter_call,
      %{duration: duration, system_time: System.system_time()},
      %{
        adapter: fields[:adapter],
        callback: fields[:callback],
        outcome: fields[:outcome],
        reason: fields[:reason],
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :identity, :refused]` - the deploy-drift
  alarm.

  Only the two content hashes ever travel, never the
  `Statifier.Machine.Identity` structs an `{:identity_mismatch, _, _}`
  term carries (ADR-0009 decision 7).
  """
  @spec identity_refused(fields :: fields()) :: :ok
  def identity_refused(fields) do
    :telemetry.execute(
      @identity_refused,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        stage: fields[:stage],
        reason: fields[:reason],
        stored_content_hash: fields[:stored_content_hash],
        supplied_content_hash: fields[:supplied_content_hash]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :execution, :created]`."
  @spec execution_created(fields :: fields()) :: :ok
  def execution_created(fields) do
    :telemetry.execute(
      @execution_created,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        child?: fields[:child?],
        metadata?: fields[:metadata?]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :terminated]`. `driven_by` is
  `:chart` for a `:done`/`:budget_exhausted` termination and `:host` for
  `StatifierPersistence.Executions.fail/4` and `cancel/3`, which no interpreter
  runs on and which upstream therefore never reports.
  """
  @spec execution_terminated(fields :: fields()) :: :ok
  def execution_terminated(fields) do
    :telemetry.execute(
      @execution_terminated,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        status: fields[:status],
        driven_by: fields[:driven_by],
        reason: fields[:reason]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :execution, :discarded]`."
  @spec execution_discarded(fields :: fields()) :: :ok
  def execution_discarded(fields) do
    :telemetry.execute(
      @execution_discarded,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        entry: fields[:entry],
        reason: fields[:reason],
        repaired?: fields[:repaired?]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :migrated]`: one execution
  re-pinned from `from_content_hash` to `to_content_hash` by
  `StatifierPersistence.Executions.migrate/4` (ADR-0013 decision 5), or
  one node of a tree re-pinned by
  `StatifierPersistence.Executions.migrate_tree/4` (ADR-0015 decision 5).
  `dropped` lists the dropped state ids that were in its configuration.
  """
  @spec execution_migrated(fields :: fields()) :: :ok
  def execution_migrated(fields) do
    :telemetry.execute(
      @execution_migrated,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        from_content_hash: fields[:from_content_hash],
        to_content_hash: fields[:to_content_hash],
        dropped: fields[:dropped]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :unparked]`: one
  `:needs_migration` execution written back to `:active` by
  `StatifierPersistence.Executions.unpark/3` (ADR-0014's telemetry
  amendment). `content_hash` is the chart it was parked on and goes on
  under.
  """
  @spec execution_unparked(fields :: fields()) :: :ok
  def execution_unparked(fields) do
    :telemetry.execute(
      @execution_unparked,
      %{system_time: System.system_time()},
      %{execution_id: fields[:execution_id], content_hash: fields[:content_hash]}
    )
  end

  @doc """
  Emits `[:statifier_persistence, :effect, :failed]` - the executor seam's
  verdict on one effect it accepted and could not perform.

  Nothing wraps a *successful* executor call: the host's work is the
  host's to instrument, and the step span already bounds it.
  """
  @spec effect_failed(fields :: fields()) :: :ok
  def effect_failed(fields) do
    :telemetry.execute(
      @effect_failed,
      %{system_time: System.system_time()},
      %{
        execution_id: fields[:execution_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        kind: fields[:kind],
        executor: fields[:executor],
        reason: fields[:reason],
        reentered?: fields[:reentered?]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :drive, :turns_exhausted]` - the drive
  loop's own refusal, reported as a point-in-time verdict rather than a
  span (ADR-0009 decision 5).
  """
  @spec drive_turns_exhausted(turns :: non_neg_integer(), fields :: fields()) :: :ok
  def drive_turns_exhausted(turns, fields) do
    :telemetry.execute(
      @drive_turns_exhausted,
      %{system_time: System.system_time(), turns: turns},
      %{execution_id: fields[:execution_id], entry: fields[:entry]}
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :migrate_batch, :start]` and
  returns the `System.monotonic_time/0` reading the batch span's close
  measures `duration` against, as `execution_step_start/3` does.

  `fields` carries `from`, `to`, `dry_run` and `span_ref`.
  """
  @spec execution_migrate_batch_start(fields :: fields()) :: integer()
  def execution_migrate_batch_start(fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_migrate_batch_start,
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      batch_metadata(fields)
    )

    monotonic_time
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :migrate_batch, :stop]`,
  `duration` in `:native` units measured from
  `execution_migrate_batch_start/1`'s reading.

  `counts` is one count per outcome of the mode - the report's `counts`,
  or every count at zero beside a whole-batch refusal - and rides as
  measurements beside `duration` and `monotonic_time`. `fields` adds
  `outcome` and `reason` to the start's.
  """
  @spec execution_migrate_batch_stop(
          start_time :: integer(),
          counts :: %{atom() => non_neg_integer()},
          fields :: fields()
        ) :: :ok
  def execution_migrate_batch_stop(start_time, counts, fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_migrate_batch_stop,
      Map.merge(counts, %{duration: monotonic_time - start_time, monotonic_time: monotonic_time}),
      Map.merge(batch_metadata(fields), %{outcome: fields[:outcome], reason: fields[:reason]})
    )
  end

  @doc """
  Emits `[:statifier_persistence, :execution, :migrate_batch, :exception]`,
  the batch span's close when the batch raised, threw or exited,
  `duration` in `:native` units measured from
  `execution_migrate_batch_start/1`'s reading.

  The caller re-raises afterwards; this function only reports. `reason`
  and `stacktrace` are narrowed as `execution_step_exception/2` narrows
  them.
  """
  @spec execution_migrate_batch_exception(start_time :: integer(), fields :: fields()) :: :ok
  def execution_migrate_batch_exception(start_time, fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @execution_migrate_batch_exception,
      %{duration: monotonic_time - start_time, monotonic_time: monotonic_time},
      Map.merge(batch_metadata(fields), %{
        kind: fields[:kind],
        reason: narrow_reason(fields[:kind], fields[:reason], fields[:stacktrace]),
        stacktrace: narrow_stacktrace(fields[:stacktrace])
      })
    )
  end

  @spec batch_metadata(fields()) :: map()
  defp batch_metadata(fields) do
    %{
      from: fields[:from],
      to: fields[:to],
      dry_run: fields[:dry_run],
      span_ref: fields[:span_ref]
    }
  end

  @doc "Emits `[:statifier_persistence, :child, :started]`."
  @spec child_started(fields :: fields()) :: :ok
  def child_started(fields) do
    :telemetry.execute(
      @child_started,
      %{system_time: System.system_time()},
      %{
        parent_execution_id: fields[:parent_execution_id],
        child_execution_id: fields[:child_execution_id],
        invoke_id: fields[:invoke_id],
        child_index: fields[:child_index],
        content_hash: fields[:content_hash],
        session_id: fields[:session_id]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :child, :refused]`."
  @spec child_refused(fields :: fields()) :: :ok
  def child_refused(fields) do
    :telemetry.execute(
      @child_refused,
      %{system_time: System.system_time()},
      %{
        parent_execution_id: fields[:parent_execution_id],
        invoke_id: fields[:invoke_id],
        reason: fields[:reason]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :child, :recorded]` - one fan-out
  child's own answer, persisted on its own execution record inside the parent's
  settlement exclusion.

  Every index but the last records an answer that never reaches the
  parent's door, so this is the only surface those answers appear on at
  all.
  """
  @spec child_recorded(fields :: fields()) :: :ok
  def child_recorded(fields) do
    :telemetry.execute(
      @child_recorded,
      %{system_time: System.system_time()},
      %{
        parent_execution_id: fields[:parent_execution_id],
        child_execution_id: fields[:child_execution_id],
        invoke_id: fields[:invoke_id],
        child_index: fields[:child_index],
        outcome: fields[:outcome]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :child, :answered]`.

  `child_count` and `failed_count` are the invocation's, and are `nil` for
  a single-child subchart, which has no invocation to aggregate.
  `failed_count` is also `nil` for a fan-out child whose answer never
  reached the parent's door (`delivery` `:parent_unfetched` or
  `:parent_chart_unresolved`), because no settlement ran. `delivery`
  is a `t:delivery/0`: what the parent's door answered, or which of the two
  ways the answer never reached it.
  """
  @spec child_answered(fields :: fields()) :: :ok
  def child_answered(fields) do
    :telemetry.execute(
      @child_answered,
      %{system_time: System.system_time()},
      %{
        child_execution_id: fields[:child_execution_id],
        parent_execution_id: fields[:parent_execution_id],
        invoke_id: fields[:invoke_id],
        outcome: fields[:outcome],
        child_count: fields[:child_count],
        failed_count: fields[:failed_count],
        delivery: fields[:delivery]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :child, :settled]` - one settlement
  decision over a whole invocation, `:answer` or `:not_yet`. `:answer` is
  the decision to answer, not the parent's acceptance of it: what the
  parent's door answered is `child_answered/1`'s `delivery`.

  `counts` is the measurement map: `child_count` and the four tallies over
  the invocation's indexes. They partition `child_count` only once every
  index has an execution of its own, which is what makes `unstarted` worth
  reading - it tells a fan-out still starting from one that is stuck.
  """
  @spec child_settled(counts :: %{atom() => non_neg_integer()}, fields :: fields()) :: :ok
  def child_settled(counts, fields) do
    :telemetry.execute(
      @child_settled,
      Map.put(counts, :system_time, System.system_time()),
      %{
        parent_execution_id: fields[:parent_execution_id],
        invoke_id: fields[:invoke_id],
        policy: fields[:policy],
        decision: fields[:decision]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :child, :cascade_cancelled]` once per
  public `StatifierPersistence.Executions.cascade_cancel/3` call, after the
  whole sweep - never once per node of the walk.
  """
  @spec child_cascade_cancelled(
          count :: non_neg_integer(),
          retained :: non_neg_integer(),
          fields :: fields()
        ) :: :ok
  def child_cascade_cancelled(count, retained, fields) do
    :telemetry.execute(
      @child_cascade_cancelled,
      %{system_time: System.system_time(), count: count, retained: retained},
      %{parent_execution_id: fields[:parent_execution_id], invoke_id: fields[:invoke_id]}
    )
  end
end
