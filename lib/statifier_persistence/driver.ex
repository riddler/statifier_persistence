defmodule StatifierPersistence.Driver do
  @moduledoc """
  Run-to-quiescence over `StatifierPersistence.Runs`: the loop that answers
  the chart's `<invoke>` calls and keeps stepping until it stops asking.

  `StatifierPersistence.Runs` steps a run *once*. That is the durable unit
  and it is deliberately small - load, step, hand the effects to an
  executor, persist - but it is not what a host wants to call. A chart that
  invokes a service is not finished when the step that emitted the
  `<invoke>` returns: it is waiting for an answer it has no way to fetch
  for itself. Every host that has embedded this package has written the
  same loop on top - step, collect the calls, perform them, feed each
  answer back, step again - and every hand-written copy of it is a place
  where a durable run can quietly stop meaning what the same chart means
  under `Statifier.Session`.

  This module is that loop, with the event construction taken from
  `Statifier.Session`'s own rather than reinvented beside it.

  ## What one drive does

  One call to `create/3` or `send_event/4` is:

  1. one `StatifierPersistence.Runs` entry point - the durable step, with
     the run's whole fetch-to-persist tail inside its serialization
     strategy;
  2. every non-lifecycle effect through the host's `:effects` executor, in
     list order, exactly as `Runs` already hands them over;
  3. every `{:invoke, _}` effect *also* through the host's `:dispatch`
     fun, synchronously, inside that same tail;
  4. after the tail has returned - never inside it - one further
     `Runs.step/5` per answer, in the order the calls were made, each of
     which can produce answers of its own;
  5. repeat from 4 until no answer is left. The result is the last step's
     own result.

  The ordering in 3 and 4 is forced rather than stylistic. Dispatch runs
  inside the tail because a call the chart made and a call the host
  performed have to be the same event in the same durable step; stepping
  runs outside it because the tail is already inside the run's
  serialization strategy, and a step issued from within would ask for
  exclusion its own caller is holding.

  ## Answers are events, and they are Session's events

  `Statifier.Session` gives a handler-backed invocation's host exactly two
  doors: `Statifier.Session.done_invocation/3` and, per st-ADR-0068,
  `Statifier.Session.failed_invocation/3`. Both build an *external* event
  and enqueue it. This module builds the same two events, field for field,
  from the same `Statifier.Evaluator.SystemVariables` writers:

  - `{:ok, donedata}` from `:dispatch` becomes
    `done.invoke.<invoke_id>`, carrying `donedata` as its data, its
    `invokeid`, and C.1's `origin`/`origintype` pair.
  - `{:error, failure}` becomes `error.communication.invoke.<invoke_id>`,
    whose data is st-ADR-0068's three string keys - `"reason"` (default
    `"unknown"`), `"attempts"` and `"detail"` (both `:undefined` when the
    host supplies none, never `nil`) - built from the same `failure`
    keyword list `failed_invocation/3` reads.

  `origin` is `#_scxml_<session id>`, and the session id comes from the
  run's own persisted `_sessionid` (spec 5.10, st-ADR-0008), which
  `Statifier.Position` carries in the datamodel across a restart. A
  resumed run therefore answers with the same origin the run started
  with, on a node that has never seen it before.

  The error arm is *permanent* failure, in st-ADR-0068's sense: the host's
  retry policy is exhausted and no `done.invoke` will follow. A transient
  failure is the host's to retry inside `:dispatch` before answering, not
  something to report to the chart.

  ## What is not answered

  A buffered answer is dropped rather than delivered when its invocation
  is no longer live by the time its turn comes - spec 6.4.3's drain-time
  discard, read off `machine_state.active_invocations` the same way
  `Statifier.Interpreter` reads it. A step that cancelled an invocation
  therefore takes that invocation's answer with it, which is what a
  session does.

  `<invoke type="scxml">` is handed to `:dispatch` like any other type.

  ## Durable subcharts

  A durable driver holds no child session between steps, so a subchart
  cannot be answered the way `Statifier.Session` answers one - by starting
  and holding a child session in memory. `:dispatch` answers a subchart
  instead: `{:start_child, invoke, {:invoke, invoke}}`, the same
  instruction `Statifier.Session.Effects` plans and that the built-in
  `Statifier.Invoke.Handler.Scxml` and `StatifierBlocks.Runtime.Subchart`
  both emit, unchanged, whichever session executes it. This module is the
  durable executor for it (ADR-0008 decision 3): it resolves and creates
  the child as an ordinary run, linked to this invocation under a
  reserved-namespace pin of the child's own chart identity
  (`StatifierPersistence.Run.Linkage`, ADR-0008 decision 2), drives that
  run to its own quiescence through this same loop - so a child that
  itself invokes a grandchild is handled with no extra code - and then
  answers `:pending` under ADR-0007 decision 1, exactly as any other
  asynchronous call does: the parent rests with the invocation live and no
  process holding it. The instruction is never renamed or reshaped, which
  is what makes a chart portable between the in-memory and durable paths.

  ## Invocations answered later

  A host whose service does not answer inside the drive - an enqueued job,
  a webhook, anything that outlives the process that started it - answers
  `:pending` from `:dispatch` instead. The call has been started; nothing
  is buffered for it; the drive rests and the position persists with the
  invocation still live in `machine_state.active_invocations`. There is no
  process holding the run in the meantime, which is the point: the run can
  wait days and survive a deploy.

  The answer arrives later through `done_invocation/5` or
  `failed_invocation/5` - the two doors `Statifier.Session` gives a live
  session's host, on the durable path and keyed by the same
  `invoke_id`. They build the same two events the in-drive path builds and
  drive the run from them, so a chart cannot tell which way its answer
  came.

  ### The cancel-versus-completion race

  An invocation the chart cancels while its call is still running has an
  answer coming for something that is no longer live - across a restart,
  on a node that has never seen the run. The liveness read that settles it
  is `active_invocations`, which `Statifier.Position` persists and
  `Statifier.Interpreter.ExitEntry` empties when the invoking state is
  exited, and it is taken *inside* the run's serialization strategy: the
  door hands `StatifierPersistence.Runs.step/5` an event builder rather
  than an event, and the builder reads the loaded position under the same
  exclusion the step itself holds. A check taken before the call would
  leave a window for a cancel to land between the read and the step.

  A cancelled invocation's answer is `{:discarded, run}` - spec 6.4.3's
  discard again, the same rule the in-drive loop applies at drain time -
  and the chart never sees it.

  This makes re-entry idempotent for the ordinary chart, which transitions
  out of the invoking state on its answer: the second delivery finds the
  invocation gone. It does *not* make it idempotent for a chart that stays
  in the invoking state after answering, because the core removes an entry
  from `active_invocations` on exit and on nothing else. That is the
  in-drive path's behavior too, not something the doors introduce, and it
  is where a host's own delivery-once discipline belongs (ADR-0007).

  ## Bounding the loop

  A chart whose answer re-arms the call it answered would drive forever.
  `:max_turns` (default 1000) bounds the answer-fed steps in one drive and
  returns `{:error, {:turns_exhausted, max_turns}}` when it is reached.
  The run is durable and quiescent at that point - every step that ran,
  persisted - so the error names a loop this driver refused to keep
  turning, not a lost position.

  ## Example

      driver =
        StatifierPersistence.Driver.new(store, machine,
          dispatch: fn type, params, _context -> MyApp.perform(type, params) end,
          effects: fn effect, _context -> MyApp.Timers.consume(effect) end,
          invoke_types: Statifier.Invoke.Types.new(types: ["myapp:authorize"]),
          serialization: {MyApp.RunLock, MyApp.RunLock}
        )

      {:ok, run, machine_state} = StatifierPersistence.Driver.create(driver, run_id)

      {:ok, run, machine_state} =
        StatifierPersistence.Driver.send_event(driver, run_id, Statifier.Event.external("go"))
  """

  alias Statifier.Effect.{CancelInvoke, Invoke}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Source
  alias Statifier.Machine.Identity
  alias Statifier.Session.Invocations
  alias StatifierPersistence.{Executor, Run, Runs, Storage, Telemetry}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage.Adapter

  @typedoc """
  What `t:dispatch/0` receives as its third argument: the executor's own
  context - the run id and the chart's content hash - plus `invoke_id`,
  this invocation's id, and `invoke`, the effect payload being dispatched.

  `invoke_id` is here and not in `t:StatifierPersistence.Executor.context/0`
  because it is not a property of the run or the step: it names one
  `<invoke>`, and only the dispatch fun is called per invocation. It is
  what an asynchronous host keys its job by, and the same string
  `done_invocation/5` and `failed_invocation/5` take back.

  `invoke` is the whole `t:Statifier.Effect.Invoke.t/0` this dispatch is
  for, and it is here for the same reason: it is a property of the one
  `<invoke>`, not of the run or the step. `type` and `params` are handed
  over as their own arguments because they are what an ordinary host acts
  on; the rest of the element - `src` above all, and `content`,
  `autoforward`, and the counters with it - reaches a host that needs it
  only through this key. `src` is spec 6.4's URI attribute, which the core
  never dereferences (st-ADR-0031): a host that resolves a chart by
  document id reads `context.invoke.src`, and a subchart handler that
  answers `{:start_child, invoke, {:invoke, invoke}}` returns the payload
  it was handed rather than synthesising one from what it happened to know
  (ADR-0007 decision 5's amendment, ADR-0008 decision 3).
  """
  @type dispatch_context :: %{
          run_id: String.t(),
          content_hash: String.t(),
          invoke_id: String.t(),
          invoke: Invoke.t()
        }

  @typedoc """
  Performs one `<invoke>` and answers it - synchronously inside the durable
  step that emitted it, or later through this module's re-entry doors.

  Receives the element's own `type` and resolved `params`
  (`t:Statifier.Effect.Invoke.t/0`'s fields) plus a `t:dispatch_context/0`,
  whose `:invoke` key carries that whole payload for a host that needs a
  field the two arguments do not name - `src` being the one a chart
  resolver keys on.
  `{:ok, donedata}` answers `done.invoke.<invoke_id>` with `donedata`;
  `{:error, failure}` answers `error.communication.invoke.<invoke_id>` with
  st-ADR-0068's `failure` keyword list (`:reason`, `:attempts`, `:detail`),
  and means permanently failed, not "try again".

  `:pending` is the asynchronous arm: the call has been *started* and will
  be answered later, by `done_invocation/5` or `failed_invocation/5`, from
  whatever process - or whatever node, after whatever restart - eventually
  has the result. Nothing is buffered for it and the drive rests, so the
  run reaches quiescence and persists with the invocation still live.

  `{:start_child, invoke, {:invoke, invoke}}` means: start this chart as
  the child of this invocation. It is `Statifier.Session.Effects`' own
  instruction, emitted unchanged by `StatifierBlocks.Runtime.Subchart` and
  by the built-in `Statifier.Invoke.Handler.Scxml` - this module executes
  it where `Statifier.Session` executes it in-memory, which is what makes a
  chart portable between the two (ADR-0008 decision 3). It is never renamed
  or reshaped, and a host never has to build this tuple itself: a subchart
  handler returns it unchanged from what it received, which is what
  `t:dispatch_context/0`'s `:invoke` key makes literally true.
  """
  @type dispatch ::
          (type :: String.t() | nil, params :: term(), context :: dispatch_context() ->
             {:ok, term()}
             | {:error, keyword()}
             | :pending
             | {:start_child, Invoke.t(), {:invoke, Invoke.t()}})

  @typedoc """
  What one drive returns: the last durable step's own result.

  `{:ok, run, machine_state}` for a run that reached quiescence with
  nothing left to answer, `{:discarded, run}` for an event delivered to a
  terminal run, and the error arms of `StatifierPersistence.Runs` plus
  this module's own `{:turns_exhausted, max_turns}`.
  """
  @type result ::
          {:ok, Run.t(), MachineState.t()}
          | {:discarded, Run.t()}
          | {:error, Runs.error() | {:turns_exhausted, pos_integer()}}

  @typedoc """
  How this driver reaches a chart it does not hold: answering a durable
  subchart's parent, whose chart is not this driver's own `machine`
  (ADR-0008 decision 3). `content_hash` is the parent run's own, read off
  its stored record.
  """
  @type chart_resolver :: (content_hash :: String.t() -> {:ok, Machine.t()} | :error)

  @typedoc """
  How this driver reaches the scheduler that holds a fan-out's not-yet-
  started children (sp-t57, ruling C9; `sob-q3y` implements it).

  `first_error` cancels the invocation's remaining children. The ones that
  already have a run are this package's own to cancel, through
  `StatifierPersistence.Runs.cascade_cancel/3`. The ones whose start job
  has not run yet have no run record at all, so nothing here can see them,
  let alone cancel them - only the scheduler that enqueued their jobs can.
  This is the call that asks it to.

  It receives the parent's run id, the invocation id, and the indices in
  `0..child_count - 1` that produced no run record - the exact set of
  start jobs to cancel, computed inside the settlement section under the
  parent's exclusion. `{:error, reason}` fails the settlement rather than
  answering a dense list whose cancelled entries it could not vouch for.

  Defaults to `nil`, "this driver cancels no start jobs": a host with no
  scheduler starts no fan-out, and a `:first_error` settlement over a
  fully-started fan-out needs none either, since every index already has
  a run for the cascade to reach.
  """
  @type child_canceller ::
          (parent_run_id :: Runs.run_id(),
           invoke_id :: String.t(),
           unstarted_indices :: [non_neg_integer()] ->
             :ok | {:error, term()})

  @enforce_keys [:store, :machine, :dispatch]
  defstruct [
    :store,
    :machine,
    :dispatch,
    :effects,
    :invoke_types,
    :serialization,
    :chart_resolver,
    :child_canceller,
    max_turns: 1_000
  ]

  @type t :: %__MODULE__{
          store: Storage.t(),
          machine: Machine.t(),
          dispatch: dispatch(),
          effects: Executor.t() | nil,
          invoke_types: MachineState.invoke_types(),
          serialization: {module(), term()} | nil,
          chart_resolver: chart_resolver() | nil,
          child_canceller: child_canceller() | nil,
          max_turns: pos_integer()
        }

  # One buffered answer: the invocation's `{state_index, invoke_index}`
  # liveness key, its id, and what the host answered with.
  @typep answer ::
           {{non_neg_integer(), non_neg_integer()}, String.t(),
            {:done, term()} | {:failed, keyword()}}

  # A child's place in a fan-out: its index, N, and the invocation's
  # aggregation policy. `nil` is the ordinary single-child subchart, which
  # records none of the three and answers its parent's door directly.
  @typep fan_out :: {non_neg_integer(), pos_integer(), Linkage.policy()} | nil

  @doc """
  Builds a driver over `store` and `machine`.

  `opts`:

  - `dispatch:` (required) - the `t:dispatch/0` fun every `<invoke>` is
    performed through.
  - `effects:` - a `t:StatifierPersistence.Executor.t/0` handed every
    non-lifecycle effect before the invoke dispatch, for the effects the
    host observes or persists itself (a `<send delay=...>` becoming a
    durable timer, a trace becoming a feed row). Defaults to `nil`, "the
    host wants none of them"; an `{:error, reason}` from it re-enters the
    chart as `error.communication` exactly as it does through
    `StatifierPersistence.Runs` directly.
  - `invoke_types:` - the `t:Statifier.Invoke.Types.t/0` snapshot stamped
    on every step. A driver-level default rather than a per-call one
    because the registered set is fixed for a session's lifetime
    (st-ADR-0051); `routes:`, which is not, stays per call. Defaults to
    `nil`, "the built-in set only".
  - `serialization:` - the `{module, config}` per-run strategy every entry
    point runs inside (ADR-0004 decision 5). Defaults to whatever
    `StatifierPersistence.Runs` defaults to, the adapter's own
    `lock_run/3`.
  - `chart_resolver:` - `t:chart_resolver/0`, how this driver reaches a
    chart it does not hold: `(content_hash -> {:ok, Statifier.Machine.t()}
    | :error)`. It exists for exactly one purpose - answering a durable
    subchart's parent, whose chart is not this driver's `machine`
    (ADR-0008 decision 3). This package cannot supply it: a stored
    `chart_blob` is opaque by ADR-0003 decision 1 and nothing here decodes
    one, so the host that saved the chart is the only party that can
    compile it. Defaults to `nil`, "this driver answers no parents" - a
    host without one calls `done_invocation/5` or `failed_invocation/5`
    itself, from `parent_link/2` and the drive's own `run.donedata` or
    `run.failure`.
  - `child_canceller:` - `t:child_canceller/0`, how a `:first_error`
    settlement reaches the scheduler holding the start jobs of a fan-out's
    not-yet-started children. Defaults to `nil`, "this driver cancels no
    start jobs".
  - `max_turns:` - the answer-fed steps one drive will take before
    refusing to take another. Defaults to 1000.

  Every one of these except `dispatch:` may be overridden per call by
  passing the same key in a `create/3` or `send_event/4` `opts` list.
  """
  @spec new(store :: Storage.t(), machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Storage{} = store, %Machine{} = machine, opts) do
    %__MODULE__{
      store: store,
      machine: machine,
      dispatch: Keyword.fetch!(opts, :dispatch),
      effects: Keyword.get(opts, :effects),
      invoke_types: Keyword.get(opts, :invoke_types),
      serialization: Keyword.get(opts, :serialization),
      chart_resolver: Keyword.get(opts, :chart_resolver),
      child_canceller: Keyword.get(opts, :child_canceller),
      max_turns: Keyword.get(opts, :max_turns, 1_000)
    }
  end

  @doc """
  Creates the run under `run_id` and drives it to quiescence.

  `StatifierPersistence.Runs.create/4` with this driver's executor, then
  the answer loop. `opts` takes everything `create/4` takes except
  `executor:`, which this module supplies - `initialize:`, `metadata:`,
  `routes:`, and per-call overrides of the driver's own `invoke_types:`
  and `serialization:`.
  """
  @spec create(driver :: t(), run_id :: Runs.run_id(), opts :: keyword()) :: result()
  def create(%__MODULE__{} = driver, run_id, opts \\ []) do
    ref = make_ref()
    opts = driver |> create_opts(opts) |> Keyword.put_new(:entry, :create)
    result = Runs.create(driver.store, run_id, driver.machine, run_opts(driver, opts, ref))
    result = advance(driver, run_id, opts, result, drain(ref, []), 0)

    maybe_answer_parent(driver, run_id, result)
  end

  # `create/4`'s `invoke_types:` has to travel inside `initialize:`, not
  # beside it: a create has no stored position to stamp, so the snapshot
  # reaches the core through `Statifier.MachineState.new/2`'s own option
  # and nowhere else. Without this, a driver-level `invoke_types:` would
  # take effect on every step of a run and not on the step that starts it,
  # and the very first `<invoke>` a chart makes - the one in its initial
  # configuration - would go unregistered.
  @spec create_opts(t(), keyword()) :: keyword()
  defp create_opts(%__MODULE__{invoke_types: nil}, opts), do: opts

  defp create_opts(%__MODULE__{invoke_types: invoke_types}, opts) do
    Keyword.update(
      opts,
      :initialize,
      [invoke_types: invoke_types],
      &Keyword.put_new(&1, :invoke_types, invoke_types)
    )
  end

  @doc """
  Delivers one external event to the run under `run_id` and drives it to
  quiescence.

  `StatifierPersistence.Runs.step/5` with this driver's executor, then the
  answer loop. An event delivered to a terminal run is that function's own
  `{:discarded, run}`, before any position decode and before any dispatch.
  """
  @spec send_event(
          driver :: t(),
          run_id :: Runs.run_id(),
          event :: Event.t(),
          opts :: keyword()
        ) :: result()
  def send_event(%__MODULE__{} = driver, run_id, %Event{} = event, opts \\ []) do
    ref = make_ref()
    opts = Keyword.put_new(opts, :entry, :step)
    result = step(driver, run_id, opts, event, ref)
    result = advance(driver, run_id, opts, result, drain(ref, []), 0)

    maybe_answer_parent(driver, run_id, result)
  end

  @doc """
  Answers a `:pending` invocation with `donedata` and drives the run to
  quiescence.

  `Statifier.Session.done_invocation/3`'s door on the durable path: it
  builds the same `done.invoke.<invoke_id>` event, from the run's own
  persisted `_sessionid`, and steps it. `invoke_id` is the `<invoke>`
  element's id - the `invoke_id` `:dispatch` was handed in its
  `t:dispatch_context/0`.

  Answering an invocation the chart has since cancelled is
  `{:discarded, run}`, spec 6.4.3's discard, decided from the loaded
  position inside the run's serialization strategy (the moduledoc's
  cancel-versus-completion section). So is answering a terminal run.

  The answer can re-arm calls of its own; they are dispatched and driven
  exactly as `send_event/4` drives them, `:pending` included.

  `opts` takes what `send_event/4` takes.
  """
  @spec done_invocation(
          driver :: t(),
          run_id :: Runs.run_id(),
          invoke_id :: String.t(),
          donedata :: term(),
          opts :: keyword()
        ) :: result()
  def done_invocation(%__MODULE__{} = driver, run_id, invoke_id, donedata \\ nil, opts \\ [])
      when is_binary(invoke_id) do
    reenter(driver, run_id, opts, invoke_id, {:done, donedata})
  end

  @doc """
  `done_invocation/5`'s failing counterpart: answers a `:pending`
  invocation with a *permanent* failure and drives the run to quiescence.

  `Statifier.Session.failed_invocation/3`'s door on the durable path,
  building the same `error.communication.invoke.<invoke_id>` event from
  st-ADR-0068's `failure` keyword list (`:reason`, `:attempts`,
  `:detail`). Permanent in that record's sense: the host's retry policy is
  exhausted and no `done.invoke` will follow. A transient failure is the
  host's to retry before answering, not something to report to the chart.

  Discards, re-armed calls and `opts` are `done_invocation/5`'s.
  """
  @spec failed_invocation(
          driver :: t(),
          run_id :: Runs.run_id(),
          invoke_id :: String.t(),
          failure :: keyword(),
          opts :: keyword()
        ) :: result()
  def failed_invocation(%__MODULE__{} = driver, run_id, invoke_id, failure \\ [], opts \\ [])
      when is_binary(invoke_id) and is_list(failure) do
    reenter(driver, run_id, opts, invoke_id, {:failed, failure})
  end

  @doc """
  The "find my parent" query: reads `run_id`'s own stored linkage, one key
  read off its fetched record (`StatifierPersistence.Run.Linkage`, ADR-0008
  decision 2).

  `:no_parent` for a run with no linkage - an ordinary run, or a durable
  subchart child that has none for whatever reason - not a failure: having
  no parent is an ordinary property of a run.
  """
  @spec parent_link(store :: Storage.t(), run_id :: Runs.run_id()) ::
          {:ok, Linkage.t()} | :no_parent | {:error, Storage.error()}
  def parent_link(%Storage{} = store, run_id) do
    with {:ok, run_record} <- Storage.fetch_run(store, run_id) do
      case Linkage.from_metadata(run_record.metadata) do
        {:ok, %Linkage{} = linkage} -> {:ok, linkage}
        :no_linkage -> :no_parent
      end
    end
  end

  @doc """
  Answers `child_run_id`'s parent with its completion or permanent failure
  (ADR-0008 decision 3) - a separate drive under the *parent's* own
  exclusion, `driver.machine` must be the parent's chart.

  `donedata_or_failure` is `{:done, donedata}` or `{:failed, failure}`.
  Reads `child_run_id`'s own linkage through `parent_link/2` first:
  `:no_parent` is a no-op answering `:no_parent`, so this is safe to call
  on any run id, linked or not.

  A child of a **fan-out** answers no parent here. Its linkage carries a
  `child_count`, so this call settles instead - records the child's own
  answer and, if it is the last, assembles the invocation's dense list and
  answers the parent's door once - and returns `:ok`. The routing is here
  and not only on the automatic path because a host driving the doors
  itself must not be able to bypass a settlement by calling this function:
  answering a fan-out's parent with one child's donedata would complete
  the whole map block on the first child to finish.

  Public so a host with no `chart_resolver:` can call it explicitly with a
  driver built over the parent's own chart - the same construction the
  automatic path (wired into `create/3`, `send_event/4`, `done_invocation/5`
  and `failed_invocation/5`) uses once its `chart_resolver:` has resolved
  one. The parent's answer is `done_invocation/5` or `failed_invocation/5`
  under the parent's own exclusion: a parent that has already cancelled the
  invocation answers `{:discarded, _}` here, which is ADR-0007 decision 3's
  mechanism doing its job, not an error.
  """
  @spec answer_parent(
          driver :: t(),
          child_run_id :: Runs.run_id(),
          donedata_or_failure :: {:done, term()} | {:failed, keyword()}
        ) :: result() | :ok | :no_parent | {:error, Storage.error()}
  def answer_parent(%__MODULE__{} = driver, child_run_id, donedata_or_failure)
      when is_binary(child_run_id) do
    case parent_link(driver.store, child_run_id) do
      {:ok, %Linkage{child_count: nil} = linkage} ->
        result = respond_to_parent(driver, linkage, donedata_or_failure)
        report_answered(child_run_id, linkage, donedata_or_failure)
        result

      {:ok, %Linkage{} = linkage} ->
        settle_child(driver, linkage, child_run_id, donedata_or_failure)

      :no_parent ->
        :no_parent

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Starts child `index` of `count` for `parent_run_id`'s `<invoke>` - the
  public start-with-index door a scheduler drives a fan-out through
  (sp-t57, ruling C4; mirrors `sob-q3y`).

  The single-child durable-subchart path creates its child from inside the
  parent's own step, because there is exactly one and the parent is
  already exclusive. A fan-out cannot: N children created inside the
  parent's step would hold the parent's exclusion for N creates. So the
  parent's step enqueues the fan-out instead, and each child is created
  later, from whatever job picks it up, through this function. That is the
  reading of statifier_blocks ADR-0008 decision 4 the fan-out needs: what
  happens under the parent's exclusion is the enqueue, and the children
  are created afterwards, idempotently and resumably.

  Idempotent, and that is what makes it resumable: the child's run id is
  `StatifierPersistence.Run.Linkage.child_run_id/3` of the same three
  values, so a re-delivered start job finds the child it already created
  and adopts it rather than creating a second one - exactly as the
  single-child path's at-least-once re-drive does.

  ## Arguments

  - `driver` - any driver over the right store. Its `machine` is not read:
    the child's chart comes from `effect`, and the parent's comes from the
    `chart_resolver:` when the settlement answers.
  - `parent_run_id` - the run whose `<invoke>` this fans out.
  - `effect` - the resolved `t:Statifier.Effect.Invoke.t/0`, or the whole
    `{:start_child, resolved, {:invoke, invoke}}` instruction a subchart
    handler answers with. The invocation id is read off it, so a caller
    passes no id separately.
  - `index` - the child's 0-based position in the list being mapped over.
  - `count` - N, recorded on every child so a settlement knows how many to
    wait for.
  - `opts` - `policy:` (`:all`, the default, or `:first_error`).

  `index` outside `0..count - 1` raises `ArgumentError` - a caller bug,
  not a storage event. The check is
  `StatifierPersistence.Run.Linkage.new/6`'s, which is the one definition
  site of the linkage's own shape; this function does not repeat it.

  ## Refusals

  `{:refused, reason}`, the same shape and the same telemetry the
  single-child path's refusal at open uses, with three added arms. An
  adapter that cannot enumerate children refuses `:child_listing_unsupported`
  as it always has; one that cannot store a run's outcome payload refuses
  `:run_outcome_unsupported`, and one that cannot answer the indexed
  status projection refuses `:run_states_unsupported`. All three are the
  same principle: a child whose invocation could never be settled is not
  started. A `parent_run_id` naming no stored run refuses `:run_not_found`.
  """
  @spec start_child_at(
          driver :: t(),
          parent_run_id :: Runs.run_id(),
          effect :: Invoke.t() | {:start_child, Invoke.t(), {:invoke, Invoke.t()}},
          index :: non_neg_integer(),
          count :: pos_integer(),
          opts :: [policy: Linkage.policy()]
        ) :: :ok | {:refused, term()}
  def start_child_at(%__MODULE__{} = driver, parent_run_id, effect, index, count, opts \\ [])
      when is_binary(parent_run_id) and is_integer(index) and index >= 0 and
             is_integer(count) and count > 0 do
    resolved = resolved_invoke(effect)
    policy = Keyword.get(opts, :policy, :all)

    with {:ok, context} <- start_context(driver, parent_run_id, resolved) do
      result = settleable(driver, context, resolved, {index, count, policy})
      report_refusal(result, context)
    end
  end

  @spec resolved_invoke(Invoke.t() | {:start_child, Invoke.t(), {:invoke, Invoke.t()}}) ::
          Invoke.t()
  defp resolved_invoke(%Invoke{} = resolved), do: resolved
  defp resolved_invoke({:start_child, %Invoke{} = resolved, {:invoke, %Invoke{}}}), do: resolved

  # The parent's own record supplies the `content_hash` a
  # `t:dispatch_context/0` carries, and reading it doubles as the check
  # that the parent exists at all: creating a child of a run that is not
  # there would leave a linked orphan nothing ever settles.
  @spec start_context(t(), Runs.run_id(), Invoke.t()) ::
          {:ok, dispatch_context()} | {:refused, term()}
  defp start_context(driver, parent_run_id, %Invoke{} = resolved) do
    case Storage.fetch_run(driver.store, parent_run_id) do
      {:ok, parent_record} ->
        {:ok,
         %{
           run_id: parent_run_id,
           content_hash: parent_record.content_hash,
           invoke_id: resolved.invoke_id,
           invoke: resolved
         }}

      {:error, reason} ->
        {:refused, reason}
    end
  end

  # The fan-out counterpart of `start_child/3`'s refusal at open, with the
  # two settlement capabilities added to the enumeration one. Kept as a
  # single expression so every arm still funnels through one
  # `report_refusal/2` return, which is what keeps the refusal event to
  # one emission site.
  @spec settleable(t(), dispatch_context(), Invoke.t(), fan_out()) :: :ok | {:refused, term()}
  defp settleable(driver, context, resolved, fan_out) do
    cond do
      not Storage.child_listing_supported?(driver.store) ->
        {:refused, :child_listing_unsupported}

      not Storage.run_outcome_supported?(driver.store) ->
        {:refused, :run_outcome_unsupported}

      not Storage.run_states_supported?(driver.store) ->
        {:refused, :run_states_unsupported}

      true ->
        resolve_child(driver, resolved, context, fan_out)
    end
  end

  # `[:statifier_persistence, :child, :answered]`, after the parent's own
  # door has returned. A run with no linkage answers nothing and reports
  # nothing: having no parent is an ordinary property of a run.
  @spec report_answered(Runs.run_id(), Linkage.t(), {:done, term()} | {:failed, keyword()}) :: :ok
  defp report_answered(child_run_id, %Linkage{} = linkage, {outcome, _payload}) do
    Telemetry.child_answered(
      child_run_id: child_run_id,
      parent_run_id: linkage.parent_run_id,
      invoke_id: linkage.invoke_id,
      outcome: outcome
    )
  end

  # `entry: :answer_parent` is telemetry only (`docs/telemetry.md`): the
  # parent's own door is `done_invocation/5` or `failed_invocation/5`, but
  # what an operator wants to see on the step is that a *child* drove it.
  @spec respond_to_parent(t(), Linkage.t(), {:done, term()} | {:failed, keyword()}) :: result()
  defp respond_to_parent(driver, %Linkage{} = linkage, {:done, donedata}) do
    done_invocation(driver, linkage.parent_run_id, linkage.invoke_id, donedata,
      entry: :answer_parent
    )
  end

  defp respond_to_parent(driver, %Linkage{} = linkage, {:failed, failure}) do
    failed_invocation(driver, linkage.parent_run_id, linkage.invoke_id, failure,
      entry: :answer_parent
    )
  end

  @spec door({:done, term()} | {:failed, keyword()}) :: Runs.entry()
  defp door({:done, _donedata}), do: :done_invocation
  defp door({:failed, _failure}), do: :failed_invocation

  # The automatic re-entry `create/3`, `send_event/4` and `reenter/5` all
  # call after their own drive returns: a completed or permanently-failed
  # run with a `chart_resolver:` and linkage answers its parent; anything
  # else - active, no linkage, no resolver - leaves the drive's own result
  # unchanged, which is always what this function returns regardless of
  # what the answer attempt does.
  @spec maybe_answer_parent(t(), Runs.run_id(), result()) :: result()
  defp maybe_answer_parent(driver, run_id, {:ok, %Run{status: :completed} = run, _ms} = result) do
    auto_answer_parent(driver, run_id, {:done, run.donedata})
    result
  end

  defp maybe_answer_parent(driver, run_id, {:ok, %Run{status: :failed} = run, _ms} = result) do
    auto_answer_parent(driver, run_id, {:failed, reason: run.failure})
    result
  end

  defp maybe_answer_parent(_driver, _run_id, result), do: result

  @spec auto_answer_parent(t(), Runs.run_id(), {:done, term()} | {:failed, keyword()}) :: :ok
  defp auto_answer_parent(%__MODULE__{chart_resolver: nil}, _run_id, _payload), do: :ok

  defp auto_answer_parent(driver, run_id, payload) do
    case parent_link(driver.store, run_id) do
      {:ok, %Linkage{} = linkage} -> resolve_and_answer(driver, linkage, run_id, payload)
      _no_parent_or_error -> :ok
    end
  end

  # -- Settlement (sp-t57, rulings C1, C3, C5, C9) ---------------------
  #
  # A fan-out child's completion is not an answer to the parent; it is one
  # of N answers the invocation is collecting. `answer_parent/3` is the one
  # place that decision is made - both the automatic path and the public
  # door reach it - and it routes on the child's own linkage carrying a
  # `child_count`. Three things then happen, in this order and for these
  # reasons:
  #
  # 1. The child's own answer is persisted on the child's run record.
  #    Nothing else keeps it: a stored record carries no donedata, so an
  #    answer that stayed on the step that produced it could not be
  #    assembled later by a node that never saw the child run.
  # 2. A settlement section runs under the PARENT's exclusion and asks,
  #    through the indexed status projection, whether every index has
  #    reached a terminal status. Under the parent's exclusion because the
  #    question and the answer that follows from it have to be one
  #    decision; through the projection because the question is asked once
  #    per child, and the listing would move N position blobs each time.
  # 3. Only the settlement that finds them all terminal reads the N
  #    payloads, assembles the dense index-ordered list, and answers the
  #    parent's ordinary door once.
  #
  # `driver.machine` must be the PARENT's chart, exactly as
  # `answer_parent/3` documents: the answer this delivers goes through the
  # parent's door, under the parent's own identity guard. The automatic
  # path arrives with the parent's chart already resolved, because
  # `resolve_and_answer/4` swaps it in before calling `answer_parent/3`.
  #
  # Two racers can both find every index terminal - each writes its own
  # status before either reads - and both will answer. The second is
  # discarded by `late_answer/3`'s liveness read, the same mechanism this
  # package already relies on for a late answer to a cancelled invocation.
  # That discard is idempotent for a chart that transitions out of the
  # invoking state on its answer, which the compiled fan-out block is.
  @spec settle_child(t(), Linkage.t(), Runs.run_id(), {:done, term()} | {:failed, keyword()}) ::
          :ok
  defp settle_child(driver, %Linkage{} = linkage, child_run_id, payload) do
    with :ok <- record_outcome(driver, child_run_id, payload),
         {:ok, {:answer, donedata}} <- decide(driver, linkage) do
      assembled = {:done, donedata}
      respond_to_parent(driver, linkage, assembled)
      report_answered(child_run_id, linkage, assembled)
    end

    :ok
  end

  # The child's status is already stored - its own step persisted it - so
  # this writes the payload beside it and re-states the same status rather
  # than deriving a new one. `update_run_status/4` is the writer that
  # carries every other stored field, both blobs included, forward
  # verbatim.
  @spec record_outcome(t(), Runs.run_id(), {:done, term()} | {:failed, keyword()}) ::
          :ok | {:error, Storage.error()}
  defp record_outcome(driver, child_run_id, payload) do
    {status, failure} = terminal_fields(payload)

    Storage.update_run_status(driver.store, child_run_id, status,
      failure: failure,
      outcome_blob: encode_outcome(payload)
    )
  end

  @spec terminal_fields({:done, term()} | {:failed, keyword()}) ::
          {Adapter.run_status(), String.t() | nil}
  defp terminal_fields({:done, _donedata}), do: {:completed, nil}

  defp terminal_fields({:failed, failure}) do
    case Keyword.get(failure, :reason) do
      reason when is_binary(reason) -> {:failed, reason}
      _absent_or_not_a_string -> {:failed, nil}
    end
  end

  # The payload is an opaque blob to storage, exactly as a position is, and
  # this module is the only party that encodes or decodes one. A donedata
  # term is whatever the chart's author put in it, so the encoding has to
  # be total over Elixir terms rather than JSON-shaped.
  @spec encode_outcome({:done, term()} | {:failed, keyword()}) :: binary()
  defp encode_outcome(payload), do: :erlang.term_to_binary(payload)

  @spec decode_outcome(binary() | nil) :: {:done, term()} | {:failed, keyword()} | nil
  defp decode_outcome(nil), do: nil
  defp decode_outcome(blob) when is_binary(blob), do: :erlang.binary_to_term(blob)

  # The settlement section. Everything from the projection read to the
  # assembly runs inside the parent's own serialization strategy, so two
  # children settling at once do not both read a half-written picture of
  # the invocation.
  @spec decide(t(), Linkage.t()) :: {:ok, {:answer, term()} | :not_yet} | {:error, term()}
  defp decide(driver, %Linkage{} = linkage) do
    {strategy, config} = settlement_strategy(driver)
    match = Linkage.invocation_match(linkage.parent_run_id, linkage.invoke_id)

    case strategy.with_run(config, linkage.parent_run_id, fn ->
           settle(driver, linkage, match)
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  @spec settlement_strategy(t()) :: {module(), term()}
  defp settlement_strategy(%__MODULE__{serialization: nil, store: store}),
    do: {AdapterLock, store}

  defp settlement_strategy(%__MODULE__{serialization: serialization}), do: serialization

  @spec settle(t(), Linkage.t(), Adapter.metadata()) ::
          {:ok, {:answer, term()} | :not_yet} | {:error, term()}
  defp settle(driver, %Linkage{} = linkage, match) do
    with {:ok, states} <- Storage.list_run_states_by_metadata(driver.store, match),
         {:ok, states, cancelled?} <- maybe_cancel(driver, linkage, states, match) do
      if settled?(states, linkage.child_count, cancelled?) do
        assemble(driver, linkage, states, cancelled?)
      else
        {:ok, :not_yet}
      end
    end
  end

  # `first_error`'s cancel, and the whole of it: the live siblings through
  # the cascade this package already has, the not-yet-started ones through
  # the scheduler's seam. Both kinds read cancelled in the dense list that
  # follows - the started ones from their own records, the unstarted ones
  # from having none.
  #
  # It reads "any child failed" rather than "this child failed" on purpose:
  # a re-driven settlement after a crash has to reach the same conclusion
  # as the one that was interrupted.
  @spec maybe_cancel(t(), Linkage.t(), [Adapter.run_state()], Adapter.metadata()) ::
          {:ok, [Adapter.run_state()], boolean()} | {:error, term()}
  defp maybe_cancel(driver, %Linkage{policy: :first_error} = linkage, states, match) do
    if Enum.any?(states, &(&1.status == :failed)) do
      with {:ok, _cancelled} <- Runs.cascade_cancel(driver.store, match, cascade_opts(driver)),
           :ok <- cancel_unstarted(driver, linkage, states),
           {:ok, states} <- Storage.list_run_states_by_metadata(driver.store, match) do
        {:ok, states, true}
      end
    else
      {:ok, states, false}
    end
  end

  defp maybe_cancel(_driver, _linkage, states, _match), do: {:ok, states, false}

  @spec cancel_unstarted(t(), Linkage.t(), [Adapter.run_state()]) :: :ok | {:error, term()}
  defp cancel_unstarted(%__MODULE__{child_canceller: nil}, _linkage, _states), do: :ok

  defp cancel_unstarted(driver, %Linkage{} = linkage, states) do
    case unstarted_indices(states, linkage.child_count) do
      [] ->
        :ok

      indices ->
        case driver.child_canceller.(linkage.parent_run_id, linkage.invoke_id, indices) do
          :ok -> :ok
          {:error, reason} -> {:error, {:child_canceller, reason}}
        end
    end
  end

  @spec unstarted_indices([Adapter.run_state()], pos_integer()) :: [non_neg_integer()]
  defp unstarted_indices(states, child_count) do
    started = MapSet.new(states, & &1.child_index)

    Enum.reject(0..(child_count - 1), &MapSet.member?(started, &1))
  end

  # Under `:all` every one of the N indices needs a run of its own in a
  # terminal status - an index whose start job has not run yet is an answer
  # still coming, not a missing one. Under a `first_error` cancel the
  # indices with no run are the start jobs the scheduler was just asked to
  # cancel, so they are settled too, and they have to be or the block could
  # never answer at all.
  @spec settled?([Adapter.run_state()], pos_integer(), boolean()) :: boolean()
  defp settled?(states, child_count, cancelled?) do
    terminal = Enum.count(states, &terminal?(&1.status))

    if cancelled? do
      terminal == length(states)
    else
      terminal == child_count
    end
  end

  @spec terminal?(Adapter.run_status()) :: boolean()
  defp terminal?(status), do: status in [:completed, :failed, :cancelled]

  # The one materialising read of a fan-out, at its last settlement: N
  # single-key fetches over the ids `Linkage.child_run_id/3` derives, which
  # needs no second query. The list is dense and index-ordered, so a chart
  # reads item `i`'s answer at position `i` whatever order the children
  # finished in.
  @spec assemble(t(), Linkage.t(), [Adapter.run_state()], boolean()) ::
          {:ok, {:answer, [map()]}} | {:error, term()}
  defp assemble(driver, %Linkage{} = linkage, states, cancelled?) do
    by_index = Map.new(states, &{&1.child_index, &1})

    0..(linkage.child_count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      case entry(driver, linkage, Map.get(by_index, index), index, cancelled?) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, {:answer, Enum.reverse(entries)}}
      {:error, _reason} = error -> error
    end
  end

  @spec entry(t(), Linkage.t(), Adapter.run_state() | nil, non_neg_integer(), boolean()) ::
          {:ok, map()} | {:error, term()}
  defp entry(_driver, _linkage, nil, index, true), do: {:ok, cancelled_entry(index)}

  defp entry(_driver, _linkage, %{status: :cancelled}, index, _cancelled?),
    do: {:ok, cancelled_entry(index)}

  defp entry(driver, %Linkage{} = linkage, %{status: status}, index, _cancelled?) do
    child_run_id = Linkage.child_run_id(linkage.parent_run_id, linkage.invoke_id, index)

    with {:ok, record} <- Storage.fetch_run(driver.store, child_run_id) do
      {:ok, outcome_entry(index, status, decode_outcome(record.outcome_blob))}
    end
  end

  # String keys, because this becomes the `done.invoke` event's data and
  # every other chart-facing payload this module builds uses them
  # (`answer_event/3`). A failed entry carries st-ADR-0068's own three
  # keys, so an author reads a failed item exactly as they read a failed
  # single invocation.
  @spec outcome_entry(
          non_neg_integer(),
          Adapter.run_status(),
          {:done, term()} | {:failed, keyword()} | nil
        ) :: map()
  defp outcome_entry(index, _status, {:done, donedata}),
    do: %{"index" => index, "status" => "completed", "donedata" => donedata}

  defp outcome_entry(index, _status, {:failed, failure}),
    do: %{"index" => index, "status" => "failed", "failure" => failure_data(failure)}

  defp outcome_entry(index, status, nil),
    do: %{"index" => index, "status" => Atom.to_string(status), "donedata" => nil}

  @spec failure_data(keyword()) :: map()
  defp failure_data(failure) do
    %{
      "reason" => Keyword.get(failure, :reason, "unknown"),
      "attempts" => Keyword.get(failure, :attempts, :undefined),
      "detail" => Keyword.get(failure, :detail, :undefined)
    }
  end

  @spec cancelled_entry(non_neg_integer()) :: map()
  defp cancelled_entry(index), do: %{"index" => index, "status" => "cancelled"}

  # `parent_driver` is built exactly as a child's is (`create_child/5`): the
  # same store, the same `serialization:`, the same `effects` executor, the
  # same `dispatch` fun, the same `chart_resolver:` - only `machine` ever
  # differs, in both directions, so a grandparent is reached by this same
  # construction recursing. Any failure resolving the parent's own record or
  # its chart is silently a no-op: the child's own result is unaffected
  # either way (`maybe_answer_parent/3`'s doc).
  @spec resolve_and_answer(
          t(),
          Linkage.t(),
          Runs.run_id(),
          {:done, term()} | {:failed, keyword()}
        ) ::
          :ok
  defp resolve_and_answer(driver, %Linkage{} = linkage, run_id, payload) do
    with {:ok, parent_record} <- Storage.fetch_run(driver.store, linkage.parent_run_id),
         {:ok, parent_machine} <- driver.chart_resolver.(parent_record.content_hash) do
      answer_parent(%{driver | machine: parent_machine}, run_id, payload)
    end

    :ok
  end

  # Both doors, which differ only in the answer they carry. The event is
  # built by a `t:StatifierPersistence.Runs.event_builder/0` rather than
  # here, so the liveness read and the step see one position under one
  # exclusion: a cancel cannot land between them.
  @spec reenter(
          t(),
          Runs.run_id(),
          keyword(),
          String.t(),
          {:done, term()} | {:failed, keyword()}
        ) :: result()
  defp reenter(driver, run_id, opts, invoke_id, answer) do
    ref = make_ref()
    opts = Keyword.put_new(opts, :entry, door(answer))
    builder = fn machine_state -> late_answer(machine_state, invoke_id, answer) end

    result =
      advance(driver, run_id, opts, step(driver, run_id, opts, builder, ref), drain(ref, []), 0)

    maybe_answer_parent(driver, run_id, result)
  end

  # The public door's own 6.4.3 read. `live?/2` keys on the invocation's
  # `{state_index, invoke_index}` because the in-drive path knows it; a
  # host that has been away for a week knows only the id, so the lookup
  # runs the other way over the same map. An id with no entry is an
  # invocation that was cancelled, or that already answered and left its
  # state - either way there is nothing live for this answer to reach.
  @spec late_answer(MachineState.t(), String.t(), {:done, term()} | {:failed, keyword()}) ::
          {:ok, Event.t()} | :discard
  defp late_answer(%MachineState{} = machine_state, invoke_id, answer) do
    if invoke_id in Map.values(machine_state.active_invocations) do
      {:ok, answer_event(machine_state, invoke_id, answer)}
    else
      :discard
    end
  end

  # The loop of the moduledoc's steps 4 and 5. `result` is carried rather
  # than rebuilt because it is what the drive returns: a discarded answer
  # leaves the previous step's result standing, unchanged.
  @spec advance(t(), Runs.run_id(), keyword(), result(), [answer()], non_neg_integer()) ::
          result()
  defp advance(_driver, _run_id, _opts, result, [], _turns), do: result

  defp advance(_driver, _run_id, _opts, {:discarded, _run} = result, _answers, _turns), do: result

  defp advance(_driver, _run_id, _opts, {:error, _reason} = result, _answers, _turns), do: result

  defp advance(%__MODULE__{max_turns: max_turns}, run_id, opts, _result, _answers, turns)
       when turns >= max_turns do
    # The drive loop's own refusal, reported as a point-in-time verdict
    # rather than a span (ADR-0009 decision 5): the loop is one turn in the
    # ordinary case, so an outer pair bracketing it would almost always
    # duplicate the single step span inside it.
    Telemetry.drive_turns_exhausted(turns, run_id: run_id, entry: opts[:entry])

    {:error, {:turns_exhausted, max_turns}}
  end

  defp advance(driver, run_id, opts, {:ok, _run, machine_state} = result, [answer | rest], turns) do
    if live?(machine_state, answer) do
      {_key, invoke_id, payload} = answer
      ref = make_ref()
      next = step(driver, run_id, opts, answer_event(machine_state, invoke_id, payload), ref)

      advance(driver, run_id, opts, next, rest ++ drain(ref, []), turns + 1)
    else
      # Spec 6.4.3's drain-time discard: the invocation this answer is for
      # is no longer live, so the answer is dropped rather than delivered.
      advance(driver, run_id, opts, result, rest, turns)
    end
  end

  @spec step(t(), Runs.run_id(), keyword(), Event.t() | Runs.event_builder(), reference()) ::
          result()
  defp step(driver, run_id, opts, event, ref) do
    Runs.step(driver.store, run_id, driver.machine, event, run_opts(driver, opts, ref))
  end

  # `executor:` is this module's to set, never the caller's - it is the
  # buffer the answer loop reads. Everything else is a default the caller's
  # own `opts` outrank, and `serialization:` is only written at all when
  # the driver carries one, so an unset driver falls through to
  # `StatifierPersistence.Runs`'s own default rather than overriding it
  # with `nil`.
  @spec run_opts(t(), keyword(), reference()) :: keyword()
  defp run_opts(driver, opts, ref) do
    opts =
      opts
      |> Keyword.put(:executor, executor(driver, ref))
      |> Keyword.put_new(:invoke_types, driver.invoke_types)

    case driver.serialization do
      nil -> opts
      serialization -> Keyword.put_new(opts, :serialization, serialization)
    end
  end

  # The executor `StatifierPersistence.Runs` calls, once per effect, in the
  # very process that called `create/3` or `send_event/4`. The host's own
  # executor sees every effect first and its refusal short-circuits the
  # dispatch, so an effect the host could not perform never becomes a call
  # the host then has to un-make.
  @spec executor(t(), reference()) :: Executor.t()
  defp executor(driver, ref) do
    reader = self()

    fn effect, context ->
      with :ok <- observe(driver.effects, effect, context) do
        perform(driver, effect, context, reader, ref)
      end
    end
  end

  @spec observe(Executor.t() | nil, Statifier.Effect.t(), Executor.context()) ::
          :ok | {:error, term()}
  defp observe(nil, _effect, _context), do: :ok
  defp observe(effects, effect, context), do: Executor.run(effects, effect, context)

  # The answer is buffered rather than returned: the step that emitted the
  # call is still running, and feeding the answer back into it from here
  # would re-enter the serialization strategy this call is already inside.
  # A message tagged with a reference minted for this one drive is an
  # ordered buffer that needs no second process and cannot outlive the
  # drive that filled it, or be read by another drive in this process.
  @spec perform(t(), Statifier.Effect.t(), Executor.context(), pid(), reference()) ::
          :ok | {:error, term()}
  defp perform(driver, {:invoke, %Invoke{} = invoke}, context, reader, ref) do
    # The whole effect rides along beside its id: `type` and `params` are
    # the two fields an ordinary host acts on, and every other one - `src`
    # above all - has no other way to reach a dispatch fun.
    context = Map.merge(context, %{invoke_id: invoke.invoke_id, invoke: invoke})

    case driver.dispatch.(invoke.type, invoke.params, context) do
      # Nothing is buffered: the call is running elsewhere and this drive
      # has no answer to feed back. The invocation stays live in
      # `active_invocations` and rides the persisted position out to
      # whatever process answers it through `done_invocation/5` or
      # `failed_invocation/5`.
      :pending ->
        :ok

      {:ok, donedata} ->
        buffer(reader, ref, invoke, {:done, donedata})

      {:error, failure} ->
        buffer(reader, ref, invoke, {:failed, failure})

      # ADR-0008 decision 3. The child is created inside the parent's own
      # serialization strategy - this runs in the executor, inside
      # `Runs.persist_tail/6`, inside `with_run/3` - because a parent that
      # believes it has a child and a child run that was never created is
      # the window statifier_blocks ADR-0008 decision 4 names as the one
      # that loses. The exclusion is per run id, and a child's id is not
      # the parent's, so nothing nests on one key.
      #
      # The answer is `:pending` in every non-refusing case: nothing is
      # buffered, the parent reaches quiescence, and the invocation rides
      # the persisted position out to whatever answers it.
      {:start_child, %Invoke{} = resolved, {:invoke, %Invoke{}}} ->
        case start_child(driver, resolved, context) do
          :ok ->
            :ok

          {:refused, detail} ->
            buffer(
              reader,
              ref,
              invoke,
              {:failed, reason: "child_run_creation_failed", detail: detail}
            )
        end
    end
  end

  # ADR-0008 decision 5. The core's own reaction to a state exiting while
  # one of its <invoke>s is still live - not routed through `dispatch`,
  # because cancelling a durable child is this package's own storage
  # operation and statifier_blocks ADR-0008 decision 4 says the handler
  # offers no durable counterpart to `cancel/2`. `context.run_id` is this
  # invocation's own run (the parent, from the cascade's point of view);
  # only this one invocation's subtree is walked, so a sibling invocation's
  # own children are untouched.
  #
  # Guarded by `child_listing_supported?/1` first, the same posture as
  # `start_child/3`'s own refusal at open: an adapter that cannot host a
  # durable subchart at all could never have a linked child to cascade
  # into, and every other invoke type fires this same effect on exit, so a
  # host that never starts one must see no behavior change - not even the
  # cost of a query it has no way to satisfy.
  #
  # A cascade failure is returned rather than swallowed: it reaches
  # `Runs`'s own re-entry wave through `reentry_origin/1`'s existing
  # `:cancel_invoke` arm and re-enters the chart as `error.communication`,
  # exactly as any other executor failure on this effect does.
  defp perform(
         driver,
         {:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}},
         context,
         _reader,
         _ref
       ) do
    if Storage.child_listing_supported?(driver.store) do
      case Runs.cascade_cancel(
             driver.store,
             Linkage.invocation_match(context.run_id, invoke_id),
             cascade_opts(driver)
           ) do
        {:ok, _newly_cancelled} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp perform(_driver, _effect, _context, _reader, _ref), do: :ok

  @spec cascade_opts(t()) :: keyword()
  defp cascade_opts(%__MODULE__{serialization: nil}), do: []
  defp cascade_opts(%__MODULE__{serialization: serialization}), do: [serialization: serialization]

  # Refuses at open when the store cannot enumerate children: a child that
  # could never be found is a child that could never be cancelled, and
  # starting one would break ADR-0008 decision 5. Same posture as ADR-0006
  # decision 3's refusal at open, and it happens before any write.
  #
  # This is also the one reporting site for
  # `[:statifier_persistence, :child, :refused]`: every refusal arm below
  # funnels back through this return, so the event is emitted once, in one
  # place, whatever refused. The arms are the unsupported adapter here, a
  # `Statifier.Invoke.Source.resolve/2` reason (ADR-0008 decision 4's three
  # in-memory reasons), `:unidentified_chart`, `:run_exists` from a
  # collision the adoption path will not adopt, and whatever reason
  # `create/3` or the adoption read answers with - the last two being
  # decision 4's one durable-only reason, a child run that could not be
  # created. Counting the arms is not the invariant; the single return is.
  @spec start_child(t(), Invoke.t(), dispatch_context()) :: :ok | {:refused, term()}
  defp start_child(driver, %Invoke{} = resolved, context) do
    result =
      if Storage.child_listing_supported?(driver.store) do
        resolve_child(driver, resolved, context, nil)
      else
        {:refused, :child_listing_unsupported}
      end

    report_refusal(result, context)
  end

  @spec report_refusal(:ok | {:refused, term()}, dispatch_context()) :: :ok | {:refused, term()}
  defp report_refusal({:refused, reason} = result, context) do
    Telemetry.child_refused(
      parent_run_id: context.run_id,
      invoke_id: context.invoke_id,
      reason: reason
    )

    result
  end

  defp report_refusal(result, _context), do: result

  # `invoke.content` is SCXML markup, and `Source.resolve/2` compiles it
  # (`Statifier.Invoke.Source`) - the durable path resolves a child exactly
  # as `Statifier.Session` does, rather than compiling it itself.
  @spec resolve_child(t(), Invoke.t(), dispatch_context(), fan_out()) ::
          :ok | {:refused, term()}
  defp resolve_child(driver, resolved, context, fan_out) do
    case Source.resolve(resolved, []) do
      {:ok, child_machine} -> identify_child(driver, resolved, context, child_machine, fan_out)
      {:error, reason} -> {:refused, reason}
    end
  end

  # The pin is mandatory (ADR-0008 decision 2): a chart with no identity
  # cannot be guarded on reload, so a child that resolves to one is refused
  # rather than started unpinned.
  @spec identify_child(t(), Invoke.t(), dispatch_context(), Machine.t(), fan_out()) ::
          :ok | {:refused, term()}
  defp identify_child(driver, resolved, context, child_machine, fan_out) do
    case Machine.identity(child_machine) do
      nil ->
        {:refused, :unidentified_chart}

      %Identity{content_hash: content_hash} ->
        create_child(driver, resolved, context, child_machine, content_hash, fan_out)
    end
  end

  # The linkage is built from the *parent's* `context.run_id`, this
  # invocation's `invoke_id`, index `0` (ADR-0008 decision 7 - fan-out is
  # not built, but the linkage does not assume one child per invocation),
  # and the child's own `content_hash`. The child is driven by
  # `%{driver | machine: child_machine}` - the same store, the same
  # serialization strategy, the same `effects` executor, the same
  # `dispatch` fun (which is what makes a grandchild work), a different
  # machine - through this module's own `create/3`, so a child whose own
  # initialization invokes gets the same treatment (decision 6's nesting,
  # with no extra code).
  @spec create_child(t(), Invoke.t(), dispatch_context(), Machine.t(), String.t(), fan_out()) ::
          :ok | {:refused, term()}
  defp create_child(driver, resolved, context, child_machine, content_hash, fan_out) do
    {child_index, linkage} = child_linkage(context, content_hash, fan_out)
    child_run_id = Linkage.child_run_id(context.run_id, context.invoke_id, child_index)
    child_driver = %{driver | machine: child_machine}
    datamodel = Invocations.seed_datamodel(resolved.params, child_machine)

    case create(child_driver, child_run_id, linkage: linkage, initialize: [datamodel: datamodel]) do
      {:ok, _run, machine_state} ->
        report_started(child_run_id, linkage, child_session_id(machine_state))

      {:error, :run_exists} ->
        adopt_child(driver.store, child_run_id, linkage)

      {:error, reason} ->
        {:refused, reason}

      {:discarded, _run} ->
        {:refused, :run_exists}
    end
  end

  # `nil` is an ordinary durable subchart: index `0`, no `child_count`,
  # no policy, and a stored metadata map byte-identical to the one this
  # path has always written. A tuple is one child of a fan-out.
  @spec child_linkage(dispatch_context(), String.t(), fan_out()) ::
          {non_neg_integer(), Linkage.t()}
  defp child_linkage(context, content_hash, nil) do
    {0, Linkage.new(context.run_id, context.invoke_id, 0, content_hash)}
  end

  defp child_linkage(context, content_hash, {index, count, policy}) do
    {index, Linkage.new(context.run_id, context.invoke_id, index, content_hash, count, policy)}
  end

  # `[:statifier_persistence, :child, :started]`. Every field comes from
  # the linkage this package just wrote (ADR-0008 decision 2), which is
  # what lets the bridge link parent and child without reading
  # `StatifierPersistence.Run.Linkage` back out of a metadata map.
  #
  # `session_id` is the child's own logical session, and it is `nil` on
  # the adoption path alone: an adopted child was created by an earlier,
  # crashed drive, so this drive has no decoded position of it and does
  # not perform a load to invent one (ADR-0009 decision 4's honest nil).
  @spec report_started(Runs.run_id(), Linkage.t(), String.t() | nil) :: :ok
  defp report_started(child_run_id, %Linkage{} = linkage, session_id) do
    Telemetry.child_started(
      parent_run_id: linkage.parent_run_id,
      child_run_id: child_run_id,
      invoke_id: linkage.invoke_id,
      child_index: linkage.child_index,
      content_hash: linkage.content_hash,
      session_id: session_id
    )
  end

  # `session_id/1`'s permissive twin: a missing correlation id on an event
  # is not a reason to fail a child that has already been created.
  @spec child_session_id(MachineState.t()) :: String.t() | nil
  defp child_session_id(%MachineState{datamodel: datamodel}),
    do: Map.get(datamodel, "_sessionid")

  # `{:error, :run_exists}` is not a failure. ADR-0004 decision 3's
  # at-least-once execution means a crash between the child create and the
  # parent's own persist re-drives this exact step; the id is deterministic
  # (`Linkage.child_run_id/3`), so the second create finds the first. A
  # collision whose linkage names this same parent and invocation is that
  # re-drive - answer `:ok` (pending) rather than refusing. A collision
  # naming something else is a genuine id clash, and is refused.
  @spec adopt_child(Storage.t(), Runs.run_id(), Linkage.t()) :: :ok | {:refused, term()}
  defp adopt_child(store, child_run_id, linkage) do
    case Storage.fetch_run(store, child_run_id) do
      {:ok, run_record} ->
        case Linkage.from_metadata(run_record.metadata) do
          {:ok, %Linkage{parent_run_id: parent_run_id, invoke_id: invoke_id}}
          when parent_run_id == linkage.parent_run_id and invoke_id == linkage.invoke_id ->
            report_started(child_run_id, linkage, nil)

          _other ->
            {:refused, :run_exists}
        end

      {:error, reason} ->
        {:refused, reason}
    end
  end

  @spec buffer(pid(), reference(), Invoke.t(), {:done, term()} | {:failed, keyword()}) :: :ok
  defp buffer(reader, ref, %Invoke{} = invoke, answer) do
    send(reader, {ref, {invoke.state_index, invoke.invoke_index}, invoke.invoke_id, answer})

    :ok
  end

  @spec drain(reference(), [answer()]) :: [answer()]
  defp drain(ref, acc) do
    receive do
      {^ref, key, invoke_id, answer} -> drain(ref, [{key, invoke_id, answer} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `Statifier.Interpreter`'s own liveness read: `active_invocations` maps
  # `{state_index, invoke_index}` to the live invocation's id, so an entry
  # that is gone or that names a different id is an invocation this answer
  # is no longer for.
  @spec live?(MachineState.t(), answer()) :: boolean()
  defp live?(%MachineState{active_invocations: invocations}, {key, invoke_id, _answer}),
    do: Map.get(invocations, key) == invoke_id

  # `Statifier.Session`'s `build_done_event/3` and `build_failure_event/3`,
  # field for field. Two events in one lifecycle, differing only in name
  # and payload, and both external: a host reports on a service's behalf,
  # the processor detected nothing (st-ADR-0068 decision 5).
  @spec answer_event(MachineState.t(), String.t(), {:done, term()} | {:failed, keyword()}) ::
          Event.t()
  defp answer_event(machine_state, invoke_id, {:done, donedata}) do
    invoked_event(machine_state, "done.invoke." <> invoke_id, invoke_id, donedata)
  end

  defp answer_event(machine_state, invoke_id, {:failed, failure}) when is_list(failure) do
    data = %{
      "reason" => Keyword.get(failure, :reason, "unknown"),
      "attempts" => Keyword.get(failure, :attempts, :undefined),
      "detail" => Keyword.get(failure, :detail, :undefined)
    }

    invoked_event(machine_state, "error.communication.invoke." <> invoke_id, invoke_id, data)
  end

  @spec invoked_event(MachineState.t(), String.t(), String.t(), term()) :: Event.t()
  defp invoked_event(machine_state, name, invoke_id, data) do
    Event.external(name,
      data: data,
      invokeid: invoke_id,
      origin: SystemVariables.scxml_location(session_id(machine_state)),
      origintype: SystemVariables.scxml_event_processor()
    )
  end

  # The bare match is the tripwire: `_sessionid` is written once by
  # `Statifier.MachineState.new/2` and carried in the persisted datamodel
  # for the run's whole life (spec 5.10, st-ADR-0008), so a run that has
  # lost it fails loudly here rather than answering with an origin no
  # `<send target>` can reach.
  @spec session_id(MachineState.t()) :: String.t()
  defp session_id(%MachineState{datamodel: %{"_sessionid" => session_id}})
       when is_binary(session_id),
       do: session_id
end
