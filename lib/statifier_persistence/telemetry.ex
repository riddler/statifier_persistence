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
  - **The step seam is the one `:start`/`:stop` pair.** This package owns
    an interval nobody else measures - lock, load, decode, identity-check,
    advance, execute effects, persist - and the upstream macrostep span
    nests inside it. `span_ref` is a fresh `make_ref/0` per span, carried
    on both halves, and is the only pairing key (`st-ADR-0040` decision 2).
    Everything else is a single point-in-time event.
  - **`run_id` is the identity key**, never `scope`; `session_id` rides
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
  `cancel/3` inside `StatifierPersistence.Runs`'s own `serialized/5`.
  Emitted on the calling process. The
  `[:statifier, :session, :macrostep, ...]` span opens and closes inside
  it.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :run, :step, :start]` | `system_time`, `monotonic_time` | `run_id`, `entry`, `span_ref` |
  | `[:statifier_persistence, :run, :step, :stop]` | `duration`, `monotonic_time` | `run_id`, `session_id`, `content_hash`, `entry`, `outcome`, `status`, `reason`, `span_ref` |
  | `[:statifier_persistence, :run, :lock]` | `duration`, `system_time` | `run_id`, `strategy`, `outcome`, `reason` |

  `entry` is which public door was used: `:create`, `:step`,
  `:done_invocation`, `:failed_invocation`, `:answer_parent`, `:fail`,
  `:cancel`. `outcome` on the stop is `:ok`, `:discarded` or `:error`.
  `[:statifier_persistence, :run, :lock]`'s `duration` is the **wait** for
  the per-run exclusion, not the held time, and its `outcome` is
  `:acquired` or `:unavailable`.

  ## The storage seam

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :adapter, :call]` | `duration`, `system_time` | `adapter`, `callback`, `outcome`, `reason`, `run_id`, `session_id`, `content_hash` |
  | `[:statifier_persistence, :identity, :refused]` | `system_time` | `run_id`, `session_id`, `stage`, `reason`, `stored_content_hash`, `supplied_content_hash` |

  `callback` is the `StatifierPersistence.Storage.Adapter` callback name, a
  closed vocabulary fixed by the behaviour. `stage` on a refusal is
  `:position`, `:run` or `:chart`, and `reason` is `:identity_mismatch` or
  `:unidentified_chart`; **only the two content hashes travel**, never the
  `Statifier.Machine.Identity` structs the error term carries.

  ## The run lifecycle seam

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :run, :created]` | `system_time` | `run_id`, `session_id`, `content_hash`, `child?`, `metadata?` |
  | `[:statifier_persistence, :run, :terminated]` | `system_time` | `run_id`, `session_id`, `content_hash`, `status`, `driven_by`, `reason` |
  | `[:statifier_persistence, :run, :discarded]` | `system_time` | `run_id`, `entry`, `reason`, `repaired?` |
  | `[:statifier_persistence, :effect, :failed]` | `system_time` | `run_id`, `session_id`, `content_hash`, `kind`, `executor`, `reason`, `reentered?` |
  | `[:statifier_persistence, :drive, :turns_exhausted]` | `system_time`, `turns` | `run_id`, `entry` |

  `driven_by` on `:terminated` is `:chart` or `:host` - `fail/4` and
  `cancel/3` are the `:host` ones, and upstream emits nothing at all for
  them. `:discarded`'s `reason` is the closed vocabulary `:terminal_run`,
  `:builder_declined`, `:position_terminal`, and only the third sets
  `repaired?: true`.

  ## The durable-subchart seam (ADR-0008)

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier_persistence, :child, :started]` | `system_time` | `parent_run_id`, `child_run_id`, `invoke_id`, `child_index`, `content_hash`, `session_id` |
  | `[:statifier_persistence, :child, :refused]` | `system_time` | `parent_run_id`, `invoke_id`, `reason` |
  | `[:statifier_persistence, :child, :answered]` | `system_time` | `child_run_id`, `parent_run_id`, `invoke_id`, `outcome` |
  | `[:statifier_persistence, :child, :cascade_cancelled]` | `system_time`, `count`, `retained` | `parent_run_id`, `invoke_id` |

  `content_hash` on `:started` is the child's *pinned* hash (ADR-0008
  decision 2). `count` on `:cascade_cancelled` is how many runs the sweep
  actually cancelled and `retained` is how many it found already terminal
  and left alone; both are legitimately `0`.

  ## Cardinality and disclosure

  Every metadata key is bounded by the chart or by a closed vocabulary
  except `run_id` (and `parent_run_id` / `child_run_id`), which is
  host-supplied and is a correlation id for a span or a log line, **never
  a metric dimension**, and `reason`, which carries an arbitrary executor
  or adapter term on some events and must be narrowed before it becomes a
  dimension.

  **Nothing host-opaque and nothing from the datamodel is ever on an
  event** (ADR-0009 decision 7): not the `chart_blob`, the
  `position_blob`, the `identity_blob`, the ADR-0006 `metadata` map, the
  datamodel, an invoke's `params`, or a `:done` effect's `donedata`.
  `metadata?` on `[:statifier_persistence, :run, :created]` is a boolean -
  whether a non-empty host map was supplied - and that is the whole of
  what this contract says about it.
  """

  @typedoc "Any event name this module emits."
  @type event_name :: [atom(), ...]

  @typedoc """
  A field list for one event: every key the contract names for it, in any
  order. A key the caller omits is emitted as `nil` rather than dropped,
  so a handler never has to `Map.get/3` its way around a shape that
  varies.
  """
  @type fields :: keyword()

  @run_step_start [:statifier_persistence, :run, :step, :start]
  @run_step_stop [:statifier_persistence, :run, :step, :stop]
  @run_lock [:statifier_persistence, :run, :lock]
  @adapter_call [:statifier_persistence, :adapter, :call]
  @identity_refused [:statifier_persistence, :identity, :refused]
  @run_created [:statifier_persistence, :run, :created]
  @run_terminated [:statifier_persistence, :run, :terminated]
  @run_discarded [:statifier_persistence, :run, :discarded]
  @effect_failed [:statifier_persistence, :effect, :failed]
  @drive_turns_exhausted [:statifier_persistence, :drive, :turns_exhausted]
  @child_started [:statifier_persistence, :child, :started]
  @child_refused [:statifier_persistence, :child, :refused]
  @child_answered [:statifier_persistence, :child, :answered]
  @child_cascade_cancelled [:statifier_persistence, :child, :cascade_cancelled]

  @events [
    @run_step_start,
    @run_step_stop,
    @run_lock,
    @adapter_call,
    @identity_refused,
    @run_created,
    @run_terminated,
    @run_discarded,
    @effect_failed,
    @drive_turns_exhausted,
    @child_started,
    @child_refused,
    @child_answered,
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
  Emits `[:statifier_persistence, :run, :step, :start]` and returns the
  `System.monotonic_time/0` reading `run_step_stop/2` measures `duration`
  against.

  Returning the reading rather than taking one is deliberate: it is the
  same reading the `monotonic_time` measurement carries, so the span's
  `duration` and the two halves' `monotonic_time` values cannot drift
  apart.
  """
  @spec run_step_start(run_id :: term(), entry :: atom(), span_ref :: reference()) :: integer()
  def run_step_start(run_id, entry, span_ref) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @run_step_start,
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      %{run_id: run_id, entry: entry, span_ref: span_ref}
    )

    monotonic_time
  end

  @doc """
  Emits `[:statifier_persistence, :run, :step, :stop]`, `duration` in
  `:native` units measured from `run_step_start/3`'s reading.
  """
  @spec run_step_stop(start_time :: integer(), fields :: fields()) :: :ok
  def run_step_stop(start_time, fields) do
    monotonic_time = System.monotonic_time()

    :telemetry.execute(
      @run_step_stop,
      %{duration: monotonic_time - start_time, monotonic_time: monotonic_time},
      %{
        run_id: fields[:run_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        entry: fields[:entry],
        outcome: fields[:outcome],
        status: fields[:status],
        reason: fields[:reason],
        span_ref: fields[:span_ref]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :run, :lock]`. `duration` is the wait
  for the per-run exclusion in `:native` units, never the held time.
  """
  @spec run_lock(duration :: integer(), fields :: fields()) :: :ok
  def run_lock(duration, fields) do
    :telemetry.execute(
      @run_lock,
      %{duration: duration, system_time: System.system_time()},
      %{
        run_id: fields[:run_id],
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
        run_id: fields[:run_id],
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
        run_id: fields[:run_id],
        session_id: fields[:session_id],
        stage: fields[:stage],
        reason: fields[:reason],
        stored_content_hash: fields[:stored_content_hash],
        supplied_content_hash: fields[:supplied_content_hash]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :run, :created]`."
  @spec run_created(fields :: fields()) :: :ok
  def run_created(fields) do
    :telemetry.execute(
      @run_created,
      %{system_time: System.system_time()},
      %{
        run_id: fields[:run_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        child?: fields[:child?],
        metadata?: fields[:metadata?]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :run, :terminated]`. `driven_by` is
  `:chart` for a `:done`/`:budget_exhausted` termination and `:host` for
  `StatifierPersistence.Runs.fail/4` and `cancel/3`, which no interpreter
  runs on and which upstream therefore never reports.
  """
  @spec run_terminated(fields :: fields()) :: :ok
  def run_terminated(fields) do
    :telemetry.execute(
      @run_terminated,
      %{system_time: System.system_time()},
      %{
        run_id: fields[:run_id],
        session_id: fields[:session_id],
        content_hash: fields[:content_hash],
        status: fields[:status],
        driven_by: fields[:driven_by],
        reason: fields[:reason]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :run, :discarded]`."
  @spec run_discarded(fields :: fields()) :: :ok
  def run_discarded(fields) do
    :telemetry.execute(
      @run_discarded,
      %{system_time: System.system_time()},
      %{
        run_id: fields[:run_id],
        entry: fields[:entry],
        reason: fields[:reason],
        repaired?: fields[:repaired?]
      }
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
        run_id: fields[:run_id],
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
      %{run_id: fields[:run_id], entry: fields[:entry]}
    )
  end

  @doc "Emits `[:statifier_persistence, :child, :started]`."
  @spec child_started(fields :: fields()) :: :ok
  def child_started(fields) do
    :telemetry.execute(
      @child_started,
      %{system_time: System.system_time()},
      %{
        parent_run_id: fields[:parent_run_id],
        child_run_id: fields[:child_run_id],
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
        parent_run_id: fields[:parent_run_id],
        invoke_id: fields[:invoke_id],
        reason: fields[:reason]
      }
    )
  end

  @doc "Emits `[:statifier_persistence, :child, :answered]`."
  @spec child_answered(fields :: fields()) :: :ok
  def child_answered(fields) do
    :telemetry.execute(
      @child_answered,
      %{system_time: System.system_time()},
      %{
        child_run_id: fields[:child_run_id],
        parent_run_id: fields[:parent_run_id],
        invoke_id: fields[:invoke_id],
        outcome: fields[:outcome]
      }
    )
  end

  @doc """
  Emits `[:statifier_persistence, :child, :cascade_cancelled]` once per
  public `StatifierPersistence.Runs.cascade_cancel/3` call, after the
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
      %{parent_run_id: fields[:parent_run_id], invoke_id: fields[:invoke_id]}
    )
  end
end
