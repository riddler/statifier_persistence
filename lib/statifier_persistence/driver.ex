defmodule StatifierPersistence.Driver do
  @moduledoc """
  Execution-to-quiescence over `StatifierPersistence.Executions`: the loop that answers
  the chart's `<invoke>` calls and keeps stepping until it stops asking.

  `StatifierPersistence.Executions` steps an execution *once*. That is the durable unit
  and it is deliberately small - load, step, hand the effects to an
  executor, persist - but it is not what a host wants to call. A chart that
  invokes a service is not finished when the step that emitted the
  `<invoke>` returns: it is waiting for an answer it has no way to fetch
  for itself. Every host that has embedded this package has written the
  same loop on top - step, collect the calls, perform them, feed each
  answer back, step again - and every hand-written copy of it is a place
  where a durable execution can quietly stop meaning what the same chart means
  under `Statifier.Session`.

  This module is that loop, with the event construction taken from
  `Statifier.Session`'s own rather than reinvented beside it.

  ## What one drive does

  One call to `create/3` or `send_event/4` is:

  1. one `StatifierPersistence.Executions` entry point - the durable step, with
     the execution's whole fetch-to-persist tail inside its serialization
     strategy;
  2. every non-lifecycle effect through the host's `:effects` executor, in
     list order, exactly as `Executions` already hands them over;
  3. every `{:invoke, _}` effect *also* through the host's `:dispatch`
     fun, synchronously, inside that same tail;
  4. after the tail has returned - never inside it - one further
     `Executions.step/5` per answer, in the order the calls were made, each of
     which can produce answers of its own;
  5. repeat from 4 until no answer is left. The result is the last step's
     own result.

  The ordering in 3 and 4 is forced rather than stylistic. Dispatch executions
  inside the tail because a call the chart made and a call the host
  performed have to be the same event in the same durable step; stepping
  runs outside it because the tail is already inside the execution's
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
  execution's own persisted `_sessionid` (spec 5.10, st-ADR-0008), which
  `Statifier.Position` carries in the datamodel across a restart. A
  resumed execution therefore answers with the same origin the execution started
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
  the child as an ordinary execution, linked to this invocation under a
  reserved-namespace pin of the child's own chart identity
  (`StatifierPersistence.Execution.Linkage`, ADR-0008 decision 2), drives that
  execution to its own quiescence through this same loop - so a child that
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
  process holding the execution in the meantime, which is the point: the execution can
  wait days and survive a deploy.

  The answer arrives later through `done_invocation/5` or
  `failed_invocation/5` - the two doors `Statifier.Session` gives a live
  session's host, on the durable path and keyed by the same
  `invoke_id`. They build the same two events the in-drive path builds and
  drive the execution from them, so a chart cannot tell which way its answer
  came.

  ### The cancel-versus-completion race

  An invocation the chart cancels while its call is still running has an
  answer coming for something that is no longer live - across a restart,
  on a node that has never seen the execution. The liveness read that settles it
  is `active_invocations`, which `Statifier.Position` persists and
  `Statifier.Interpreter.ExitEntry` empties when the invoking state is
  exited, and it is taken *inside* the execution's serialization strategy: the
  door hands `StatifierPersistence.Executions.step/5` an event builder rather
  than an event, and the builder reads the loaded position under the same
  exclusion the step itself holds. A check taken before the call would
  leave a window for a cancel to land between the read and the step.

  A cancelled invocation's answer is `{:discarded, execution}` - spec 6.4.3's
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
  The execution is durable and quiescent at that point - every step that ran,
  persisted - so the error names a loop this driver refused to keep
  turning, not a lost position.

  ## Example

      driver =
        StatifierPersistence.Driver.new(store, machine,
          dispatch: fn type, params, _context -> MyApp.perform(type, params) end,
          effects: fn effect, _context -> MyApp.Timers.consume(effect) end,
          invoke_types: Statifier.Invoke.Types.new(types: ["myapp:authorize"]),
          serialization: {MyApp.ExecutionLock, MyApp.ExecutionLock}
        )

      {:ok, execution, machine_state} = StatifierPersistence.Driver.create(driver, execution_id)

      {:ok, execution, machine_state} =
        StatifierPersistence.Driver.send_event(driver, execution_id, Statifier.Event.external("go"))
  """

  alias Statifier.Effect.{CancelInvoke, Invoke}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Source
  alias Statifier.Machine.Identity
  alias Statifier.Session.Invocations
  alias StatifierPersistence.{Execution, Executions, Executor, Storage, Telemetry}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage.Adapter

  @typedoc """
  What `t:dispatch/0` receives as its third argument: the executor's own
  context - the execution id and the chart's content hash - plus `invoke_id`,
  this invocation's id, and `invoke`, the effect payload being dispatched.

  `invoke_id` is here and not in `t:StatifierPersistence.Executor.context/0`
  because it is not a property of the execution or the step: it names one
  `<invoke>`, and only the dispatch fun is called per invocation. It is
  what an asynchronous host keys its job by, and the same string
  `done_invocation/5` and `failed_invocation/5` take back.

  `invoke` is the whole `t:Statifier.Effect.Invoke.t/0` this dispatch is
  for, and it is here for the same reason: it is a property of the one
  `<invoke>`, not of the execution or the step. `type` and `params` are handed
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
          execution_id: String.t(),
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
  execution reaches quiescence and persists with the invocation still live.

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

  `{:ok, execution, machine_state}` for an execution that reached quiescence with
  nothing left to answer, `{:discarded, execution}` for an event delivered to a
  terminal execution, and the error arms of `StatifierPersistence.Executions` plus
  this module's own `{:turns_exhausted, max_turns}`.
  """
  @type result ::
          {:ok, Execution.t(), MachineState.t()}
          | {:discarded, Execution.t()}
          | {:error, Executions.error() | {:turns_exhausted, pos_integer()}}

  @typedoc """
  How this driver reaches a chart it does not hold: answering a durable
  subchart's parent, whose chart is not this driver's own `machine`
  (ADR-0008 decision 3). `content_hash` is the parent execution's own, read off
  its stored record.
  """
  @type chart_resolver :: (content_hash :: String.t() -> {:ok, Machine.t()} | :error)

  @typedoc """
  How this driver reaches the scheduler that holds a fan-out's not-yet-
  started children (sp-t57, ruling C9; `sob-q3y` implements it).

  `first_error` cancels the invocation's remaining children. The ones that
  already have an execution are this package's own to cancel, through
  `StatifierPersistence.Executions.cascade_cancel/3`. The ones whose start job
  has not run yet have no execution record at all, so nothing here can see them,
  let alone cancel them - only the scheduler that enqueued their jobs can.
  This is the call that asks it to.

  It receives the parent's execution id, the invocation id, and the indices in
  `0..child_count - 1` that produced no execution record - the exact set of
  start jobs to cancel, computed inside the settlement section under the
  parent's exclusion. `{:error, reason}` fails the settlement rather than
  answering a dense list whose cancelled entries it could not vouch for.

  Defaults to `nil`, "this driver cancels no start jobs": a host with no
  scheduler starts no fan-out, and a `:first_error` settlement over a
  fully-started fan-out needs none either, since every index already has
  an execution for the cascade to reach.
  """
  @type child_canceller ::
          (parent_execution_id :: Executions.execution_id(),
           invoke_id :: String.t(),
           unstarted_indices :: [non_neg_integer()] ->
             :ok | {:error, term()})

  @typedoc """
  ADR-0008's `after_step:` callback (the 2026-09-08 amendment): the id of
  the execution that was stepped, the `t:Statifier.MachineState.t/0` that step's
  result carries, and the whole effect list that step produced - lifecycle
  effects included, not the executable subset `effects:` sees.

  It is an observer: its return value is discarded, and a raise inside it
  propagates to the caller rather than being swallowed (the amendment's
  clause 4).
  """
  @type after_step ::
          (execution_id :: Executions.execution_id(),
           machine_state :: MachineState.t(),
           effects :: [Statifier.Effect.t()] ->
             any())

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
    :after_step,
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
          after_step: after_step() | nil,
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
    `StatifierPersistence.Executions` directly.
  - `invoke_types:` - the `t:Statifier.Invoke.Types.t/0` snapshot stamped
    on every step. A driver-level default rather than a per-call one
    because the registered set is fixed for a session's lifetime
    (st-ADR-0051); `routes:`, which is not, stays per call. Defaults to
    `nil`, "the built-in set only".
  - `serialization:` - the `{module, config}` per-execution strategy every entry
    point runs inside (ADR-0004 decision 5). Defaults to whatever
    `StatifierPersistence.Executions` defaults to, the adapter's own
    `lock_execution/3`.
  - `chart_resolver:` - `t:chart_resolver/0`, how this driver reaches a
    chart it does not hold: `(content_hash -> {:ok, Statifier.Machine.t()}
    | :error)`. It exists for exactly one purpose - answering a durable
    subchart's parent, whose chart is not this driver's `machine`
    (ADR-0008 decision 3). This package cannot supply it: a stored
    `chart_blob` is opaque by ADR-0003 decision 1 and nothing here decodes
    one, so the host that saved the chart is the only party that can
    compile it. Defaults to `nil`, "this driver answers no parents" - a
    host without one calls `done_invocation/5` or `failed_invocation/5`
    itself, from `parent_link/2` and the drive's own `execution.donedata` or
    `execution.failure`.
  - `child_canceller:` - `t:child_canceller/0`, how a `:first_error`
    settlement reaches the scheduler holding the start jobs of a fan-out's
    not-yet-started children. Defaults to `nil`, "this driver cancels no
    start jobs".
  - `after_step:` - `t:after_step/0`, called
    `after_step.(execution_id, machine_state, effects)` after every step this
    driver takes on a caller's behalf, so a host keeping its own record of
    what an execution did can append the steps it never made itself: a durable
    subchart child's own steps, and the *parent's* step on the answer path
    (ADR-0008 decision 3 and the `driver:` option on
    `StatifierPersistence.Executions.fail/4`), neither of which the drive's
    return value reports. The execution id is always the execution that was stepped -
    the parent's, on the answer path. It fires after that step's persist,
    in the order the steps happened, and outside the exclusion of the execution
    it reports; a step that was discarded, and a `cascade_cancel`, step
    nothing and fire nothing. Its return is ignored and a raise inside it
    propagates (the 2026-09-08 amendment's clauses 3 to 5, which also say
    why this is not ADR-0009's telemetry). Defaults to `nil`, "this driver
    reports no steps".
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
      after_step: Keyword.get(opts, :after_step),
      max_turns: Keyword.get(opts, :max_turns, 1_000)
    }
  end

  @doc """
  Creates the execution under `execution_id` and drives it to quiescence.

  `StatifierPersistence.Executions.create/4` with this driver's executor, then
  the answer loop. `opts` takes everything `create/4` takes except
  `executor:`, which this module supplies - `initialize:`, `metadata:`,
  `routes:`, and per-call overrides of the driver's own `invoke_types:`
  and `serialization:`.
  """
  @spec create(driver :: t(), execution_id :: Executions.execution_id(), opts :: keyword()) ::
          result()
  def create(%__MODULE__{} = driver, execution_id, opts \\ []) do
    ref = make_ref()
    opts = driver |> create_opts(opts) |> Keyword.put_new(:entry, :create)

    result =
      driver.store
      |> Executions.create(execution_id, driver.machine, execution_opts(driver, opts, ref))
      |> fire_after_step(driver, execution_id, opts, ref)

    result = advance(driver, execution_id, opts, result, drain(ref, []), 0)

    maybe_answer_parent(driver, execution_id, result)
  end

  # `create/4`'s `invoke_types:` has to travel inside `initialize:`, not
  # beside it: a create has no stored position to stamp, so the snapshot
  # reaches the core through `Statifier.MachineState.new/2`'s own option
  # and nowhere else. Without this, a driver-level `invoke_types:` would
  # take effect on every step of an execution and not on the step that starts it,
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
  Delivers one external event to the execution under `execution_id` and drives it to
  quiescence.

  `StatifierPersistence.Executions.step/5` with this driver's executor, then the
  answer loop. An event delivered to a terminal execution is that function's own
  `{:discarded, execution}`, before any position decode and before any dispatch.
  """
  @spec send_event(
          driver :: t(),
          execution_id :: Executions.execution_id(),
          event :: Event.t(),
          opts :: keyword()
        ) :: result()
  def send_event(%__MODULE__{} = driver, execution_id, %Event{} = event, opts \\ []) do
    ref = make_ref()
    opts = Keyword.put_new(opts, :entry, :step)
    result = step(driver, execution_id, opts, event, ref)
    result = advance(driver, execution_id, opts, result, drain(ref, []), 0)

    maybe_answer_parent(driver, execution_id, result)
  end

  @doc """
  Answers a `:pending` invocation with `donedata` and drives the execution to
  quiescence.

  `Statifier.Session.done_invocation/3`'s door on the durable path: it
  builds the same `done.invoke.<invoke_id>` event, from the execution's own
  persisted `_sessionid`, and steps it. `invoke_id` is the `<invoke>`
  element's id - the `invoke_id` `:dispatch` was handed in its
  `t:dispatch_context/0`.

  Answering an invocation the chart has since cancelled is
  `{:discarded, execution}`, spec 6.4.3's discard, decided from the loaded
  position inside the execution's serialization strategy (the moduledoc's
  cancel-versus-completion section). So is answering a terminal execution.

  The answer can re-arm calls of its own; they are dispatched and driven
  exactly as `send_event/4` drives them, `:pending` included.

  `opts` takes what `send_event/4` takes.
  """
  @spec done_invocation(
          driver :: t(),
          execution_id :: Executions.execution_id(),
          invoke_id :: String.t(),
          donedata :: term(),
          opts :: keyword()
        ) :: result()
  def done_invocation(
        %__MODULE__{} = driver,
        execution_id,
        invoke_id,
        donedata \\ nil,
        opts \\ []
      )
      when is_binary(invoke_id) do
    reenter(driver, execution_id, opts, invoke_id, {:done, donedata})
  end

  @doc """
  `done_invocation/5`'s failing counterpart: answers a `:pending`
  invocation with a *permanent* failure and drives the execution to quiescence.

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
          execution_id :: Executions.execution_id(),
          invoke_id :: String.t(),
          failure :: keyword(),
          opts :: keyword()
        ) :: result()
  def failed_invocation(
        %__MODULE__{} = driver,
        execution_id,
        invoke_id,
        failure \\ [],
        opts \\ []
      )
      when is_binary(invoke_id) and is_list(failure) do
    reenter(driver, execution_id, opts, invoke_id, {:failed, failure})
  end

  @doc """
  The "find my parent" query: reads `execution_id`'s own stored linkage, one key
  read off its fetched record (`StatifierPersistence.Execution.Linkage`, ADR-0008
  decision 2).

  `:no_parent` for an execution with no linkage - an ordinary execution, or a durable
  subchart child that has none for whatever reason - not a failure: having
  no parent is an ordinary property of an execution.
  """
  @spec parent_link(store :: Storage.t(), execution_id :: Executions.execution_id()) ::
          {:ok, Linkage.t()} | :no_parent | {:error, Storage.error()}
  def parent_link(%Storage{} = store, execution_id) do
    with {:ok, execution_record} <- Storage.fetch_execution(store, execution_id) do
      case Linkage.from_metadata(execution_record.metadata) do
        {:ok, %Linkage{} = linkage} -> {:ok, linkage}
        :no_linkage -> :no_parent
      end
    end
  end

  @doc """
  Answers `child_execution_id`'s parent with its completion or permanent failure
  (ADR-0008 decision 3) - a separate drive under the *parent's* own
  exclusion, `driver.machine` must be the parent's chart.

  `donedata_or_failure` is `{:done, donedata}` or `{:failed, failure}`.
  Reads `child_execution_id`'s own linkage through `parent_link/2` first:
  `:no_parent` is a no-op answering `:no_parent`, so this is safe to call
  on any execution id, linked or not.

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
          child_execution_id :: Executions.execution_id(),
          donedata_or_failure :: {:done, term()} | {:failed, keyword()}
        ) :: result() | :ok | :no_parent | {:error, Storage.error()}
  def answer_parent(%__MODULE__{} = driver, child_execution_id, donedata_or_failure)
      when is_binary(child_execution_id) do
    case parent_link(driver.store, child_execution_id) do
      {:ok, %Linkage{child_count: nil} = linkage} ->
        result = respond_to_parent(driver, linkage, donedata_or_failure)
        report_answered(child_execution_id, linkage, donedata_or_failure)
        result

      {:ok, %Linkage{} = linkage} ->
        settle_child(driver, linkage, child_execution_id, donedata_or_failure)

      :no_parent ->
        :no_parent

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  `answer_parent/3` with the parent's chart resolved first, and the same
  answer whatever happens: `:ok`.

  This is the public form of what the automatic path does once a drive of
  the *child* has left it terminal - resolve the parent's chart through
  `chart_resolver:`, then answer through `answer_parent/3` with a driver
  over that chart - and it exists because a caller outside a drive needs
  the same two steps. `StatifierPersistence.Executions.fail/4`'s `driver:` option
  is that caller (ADR-0008's outside-fail note): an execution failed from outside
  the interpreter has no drive to hang the answer off, so it calls here.

  A driver with no `chart_resolver:` answers through `answer_parent/3`
  directly, on `driver.machine` - that function's own contract, where the
  driver was built over the parent's chart by the caller. The automatic
  path deliberately does *not* do this: it is entered from a drive of the
  child, so its `driver.machine` is the child's chart and answering with it
  would step the parent against the wrong chart. Here the caller chose the
  driver, so the choice is theirs to make.

  Never raises for an execution with no parent and never reports a storage error:
  `:no_parent` and a failed fetch are both `:ok`, exactly as the automatic
  path treats them. A caller that needs the answer's own result calls
  `answer_parent/3`.
  """
  @spec resolve_and_answer_parent(
          driver :: t(),
          child_execution_id :: Executions.execution_id(),
          donedata_or_failure :: {:done, term()} | {:failed, keyword()}
        ) :: :ok
  def resolve_and_answer_parent(%__MODULE__{} = driver, child_execution_id, donedata_or_failure)
      when is_binary(child_execution_id) do
    case parent_link(driver.store, child_execution_id) do
      {:ok, %Linkage{} = linkage} ->
        answer_resolved(driver, linkage, child_execution_id, donedata_or_failure)

      _no_parent_or_error ->
        :ok
    end
  end

  @spec answer_resolved(
          t(),
          Linkage.t(),
          Executions.execution_id(),
          {:done, term()} | {:failed, keyword()}
        ) ::
          :ok
  defp answer_resolved(
         %__MODULE__{chart_resolver: nil} = driver,
         _linkage,
         child_execution_id,
         payload
       ) do
    answer_parent(driver, child_execution_id, payload)

    :ok
  end

  defp answer_resolved(driver, %Linkage{} = linkage, child_execution_id, payload) do
    resolve_and_answer(driver, linkage, child_execution_id, payload)
  end

  @doc """
  Starts child `index` of `count` for `parent_execution_id`'s `<invoke>` - the
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

  Idempotent, and that is what makes it resumable: the child's execution id is
  `StatifierPersistence.Execution.Linkage.child_execution_id/3` of the same three
  values, so a re-delivered start job finds the child it already created
  and adopts it rather than creating a second one - exactly as the
  single-child path's at-least-once re-drive does.

  ## Arguments

  - `driver` - any driver over the right store. Its `machine` is not read:
    the child's chart comes from `effect`, and the parent's comes from the
    `chart_resolver:` when the settlement answers.
  - `parent_execution_id` - the execution whose `<invoke>` this fans out.
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
  `StatifierPersistence.Execution.Linkage.new/6`'s, which is the one definition
  site of the linkage's own shape; this function does not repeat it.

  ## Refusals

  `{:refused, reason}`, the same shape and the same telemetry the
  single-child path's refusal at open uses, with three added arms. An
  adapter that cannot enumerate children refuses `:child_listing_unsupported`
  as it always has; one that cannot store an execution's outcome payload refuses
  `:execution_outcome_unsupported`, and one that cannot answer the indexed
  status projection refuses `:execution_states_unsupported`. All three are the
  same principle: a child whose invocation could never be settled is not
  started. A `parent_execution_id` naming no stored execution refuses `:execution_not_found`.
  """
  @spec start_child_at(
          driver :: t(),
          parent_execution_id :: Executions.execution_id(),
          effect :: Invoke.t() | {:start_child, Invoke.t(), {:invoke, Invoke.t()}},
          index :: non_neg_integer(),
          count :: pos_integer(),
          opts :: [policy: Linkage.policy()]
        ) :: :ok | {:refused, term()}
  def start_child_at(
        %__MODULE__{} = driver,
        parent_execution_id,
        effect,
        index,
        count,
        opts \\ []
      )
      when is_binary(parent_execution_id) and is_integer(index) and index >= 0 and
             is_integer(count) and count > 0 do
    resolved = resolved_invoke(effect)
    policy = Keyword.get(opts, :policy, :all)

    with {:ok, context} <- start_context(driver, parent_execution_id, resolved) do
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
  # that the parent exists at all: creating a child of an execution that is not
  # there would leave a linked orphan nothing ever settles.
  @spec start_context(t(), Executions.execution_id(), Invoke.t()) ::
          {:ok, dispatch_context()} | {:refused, term()}
  defp start_context(driver, parent_execution_id, %Invoke{} = resolved) do
    case Storage.fetch_execution(driver.store, parent_execution_id) do
      {:ok, parent_record} ->
        {:ok,
         %{
           execution_id: parent_execution_id,
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

      not Storage.execution_outcome_supported?(driver.store) ->
        {:refused, :execution_outcome_unsupported}

      not Storage.execution_states_supported?(driver.store) ->
        {:refused, :execution_states_unsupported}

      true ->
        resolve_child(driver, resolved, context, fan_out)
    end
  end

  # `[:statifier_persistence, :child, :answered]`, after the parent's own
  # door has returned. An execution with no linkage answers nothing and reports
  # nothing: having no parent is an ordinary property of an execution.
  @spec report_answered(
          Executions.execution_id(),
          Linkage.t(),
          {:done, term()} | {:failed, keyword()}
        ) :: :ok
  defp report_answered(child_execution_id, %Linkage{} = linkage, {outcome, _payload}) do
    Telemetry.child_answered(
      child_execution_id: child_execution_id,
      parent_execution_id: linkage.parent_execution_id,
      invoke_id: linkage.invoke_id,
      outcome: outcome,
      child_count: linkage.child_count,
      failed_count: nil
    )
  end

  # A fan-out's `outcome` is the *invocation's*, not the door's (sp-8wv's
  # ADR-0009 amendment). The parent is always answered through
  # `done_invocation/5` - a fan-out that lost an index still delivers a
  # dense list, and st-ADR-0068's failure shape is inside the entry rather
  # than around the list - so reporting the door here said `outcome: :done`
  # for a settlement that failed, which is the one thing a consumer counts
  # this event to learn. The entries are what the parent is about to be
  # answered with, so they are what the report reads.
  @spec report_settled_answer(Executions.execution_id(), Linkage.t(), [map()]) :: :ok
  defp report_settled_answer(child_execution_id, %Linkage{} = linkage, entries) do
    failed_count = Enum.count(entries, &(&1["status"] == "failed"))

    Telemetry.child_answered(
      child_execution_id: child_execution_id,
      parent_execution_id: linkage.parent_execution_id,
      invoke_id: linkage.invoke_id,
      outcome: if(failed_count > 0, do: :failed, else: :done),
      child_count: linkage.child_count,
      failed_count: failed_count
    )
  end

  # `entry: :answer_parent` names the door the parent's step came through
  # (`docs/telemetry.md`): the parent's own door is `done_invocation/5` or
  # `failed_invocation/5`, but what an operator wants to see on the step is
  # that a *child* drove it. It is not telemetry only - since ADR-0010
  # decision 5, on an adapter that keeps an input log `entry:` also stamps
  # the `door` of the entry appended to the *parent's* log, which is where
  # a replay reads this re-entry back from.
  # `invoke_id:` and `child_count:` ride beside it for the same reason and
  # are telemetry only (sp-8wv's ADR-0009 amendment): they are what
  # makes the step span carrying a whole fan-out's assembled answer
  # recognisable as that, and not an ordinary invocation answer.
  @spec respond_to_parent(t(), Linkage.t(), {:done, term()} | {:failed, keyword()}) :: result()
  defp respond_to_parent(driver, %Linkage{} = linkage, {:done, donedata}) do
    done_invocation(
      driver,
      linkage.parent_execution_id,
      linkage.invoke_id,
      donedata,
      answer_opts(linkage)
    )
  end

  defp respond_to_parent(driver, %Linkage{} = linkage, {:failed, failure}) do
    failed_invocation(
      driver,
      linkage.parent_execution_id,
      linkage.invoke_id,
      failure,
      answer_opts(linkage)
    )
  end

  @spec answer_opts(Linkage.t()) :: keyword()
  defp answer_opts(%Linkage{} = linkage) do
    [
      entry: :answer_parent,
      invoke_id: linkage.invoke_id,
      child_count: linkage.child_count
    ]
  end

  @spec door({:done, term()} | {:failed, keyword()}) :: Executions.entry()
  defp door({:done, _donedata}), do: :done_invocation
  defp door({:failed, _failure}), do: :failed_invocation

  # The automatic re-entry `create/3`, `send_event/4` and `reenter/5` all
  # call after their own drive returns: a completed or permanently-failed
  # execution with a `chart_resolver:` and linkage answers its parent; anything
  # else - active, no linkage, no resolver - leaves the drive's own result
  # unchanged, which is always what this function returns regardless of
  # what the answer attempt does.
  @spec maybe_answer_parent(t(), Executions.execution_id(), result()) :: result()
  defp maybe_answer_parent(
         driver,
         execution_id,
         {:ok, %Execution{status: :completed} = execution, _ms} = result
       ) do
    auto_answer_parent(driver, execution_id, {:done, execution.donedata})
    result
  end

  defp maybe_answer_parent(
         driver,
         execution_id,
         {:ok, %Execution{status: :failed} = execution, _ms} = result
       ) do
    auto_answer_parent(driver, execution_id, {:failed, reason: execution.failure})
    result
  end

  defp maybe_answer_parent(_driver, _execution_id, result), do: result

  @spec auto_answer_parent(t(), Executions.execution_id(), {:done, term()} | {:failed, keyword()}) ::
          :ok
  defp auto_answer_parent(%__MODULE__{chart_resolver: nil}, _execution_id, _payload), do: :ok

  defp auto_answer_parent(driver, execution_id, payload) do
    resolve_and_answer_parent(driver, execution_id, payload)
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
  # 1. A settlement section takes the PARENT's exclusion. Everything that
  #    follows happens inside it, because the question and the answer that
  #    follows from it have to be one decision.
  # 2. The child's own answer is persisted on the child's execution record.
  #    Nothing else keeps it: a stored record carries no donedata, so an
  #    answer that stayed on the step that produced it could not be
  #    assembled later by a node that never saw the child execution. It is
  #    written under the parent's exclusion (sp-kl3) so that every
  #    invocation's answers are written and read in one order: the
  #    settlement that records the last answer is the settlement that then
  #    sees them all.
  # 3. The section asks, through the indexed status projection, whether
  #    every index has reached a terminal status - through the projection
  #    because the question is asked once per child, and the listing would
  #    move N position blobs each time.
  # 4. The settlement that finds them all terminal reads the N payloads
  #    and assembles the dense index-ordered list. A terminal status is
  #    necessary but not sufficient: a child's status is persisted by its
  #    own drive and its answer by the settlement that follows, so a
  #    terminal index whose answer has not been recorded yet is an answer
  #    still in flight, not a missing one, and the read yields `:not_yet`
  #    rather than an entry with a nil donedata (sp-kl3). Only the
  #    settlement that reads N recorded answers answers the parent's
  #    ordinary door, once.
  #
  # `driver.machine` must be the PARENT's chart, exactly as
  # `answer_parent/3` documents: the answer this delivers goes through the
  # parent's door, under the parent's own identity guard. The automatic
  # path arrives with the parent's chart already resolved, because
  # `resolve_and_answer/4` swaps it in before calling `answer_parent/3`.
  #
  # Two settlements can still both find the invocation settled and both
  # answer - a re-delivered job settling a child that already recorded its
  # answer is the ordinary way. The second is discarded by
  # `late_answer/3`'s liveness read, the same mechanism this
  # package already relies on for a late answer to a cancelled invocation.
  # That discard is idempotent for a chart that transitions out of the
  # invoking state on its answer, which the compiled fan-out block is.
  @spec settle_child(
          t(),
          Linkage.t(),
          Executions.execution_id(),
          {:done, term()} | {:failed, keyword()}
        ) ::
          :ok
  defp settle_child(driver, %Linkage{} = linkage, child_execution_id, payload) do
    case decide(driver, linkage, child_execution_id, payload) do
      {:ok, {:answer, entries}} ->
        respond_to_parent(driver, linkage, {:done, entries})
        report_settled_answer(child_execution_id, linkage, entries)

      _not_yet_or_error ->
        :ok
    end

    :ok
  end

  # The child's status is already stored - its own step persisted it - so
  # this writes the payload beside it and re-states the same status rather
  # than deriving a new one. `update_execution_status/4` is the writer that
  # carries every other stored field, both blobs included, forward
  # verbatim.
  #
  # Called from inside `decide/4`'s exclusion, never outside it: see the
  # section comment above.
  @spec record_outcome(t(), Executions.execution_id(), {:done, term()} | {:failed, keyword()}) ::
          :ok | {:error, Storage.error()}
  defp record_outcome(driver, child_execution_id, payload) do
    {status, failure} = terminal_fields(payload)

    Storage.update_execution_status(driver.store, child_execution_id, status,
      failure: failure,
      outcome_blob: encode_outcome(payload)
    )
  end

  @spec terminal_fields({:done, term()} | {:failed, keyword()}) ::
          {Adapter.execution_status(), String.t() | nil}
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

  # The settlement section. Everything from this child's own answer being
  # recorded through the projection read to the assembly runs inside the
  # parent's own serialization strategy, so two children settling at once
  # neither read a half-written picture of the invocation nor write their
  # answers into one.
  @spec decide(
          t(),
          Linkage.t(),
          Executions.execution_id(),
          {:done, term()} | {:failed, keyword()}
        ) ::
          {:ok, {:answer, term()} | :not_yet} | {:error, term()}
  defp decide(driver, %Linkage{} = linkage, child_execution_id, payload) do
    {strategy, config} = settlement_strategy(driver)
    match = Linkage.invocation_match(linkage.parent_execution_id, linkage.invoke_id)

    case strategy.with_execution(config, linkage.parent_execution_id, fn ->
           record_and_settle(driver, linkage, match, child_execution_id, payload)
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  # The exclusion's whole body: this child's own answer written, then the
  # question asked of every index. In this order because the answer is one
  # of the facts the question is about.
  @spec record_and_settle(
          t(),
          Linkage.t(),
          Adapter.metadata(),
          Executions.execution_id(),
          {:done, term()} | {:failed, keyword()}
        ) :: {:ok, {:answer, term()} | :not_yet} | {:error, term()}
  defp record_and_settle(driver, %Linkage{} = linkage, match, child_execution_id, payload) do
    case record_outcome(driver, child_execution_id, payload) do
      :ok ->
        report_recorded(child_execution_id, linkage, payload)
        settle(driver, linkage, match)

      {:error, _reason} = error ->
        error
    end
  end

  # `[:statifier_persistence, :child, :recorded]`, after the write and
  # inside the same exclusion, so the report cannot claim an answer the
  # settlement that follows will not read. Every index but the settling one
  # records an answer that reaches no door at all, and before this event
  # nothing showed them (sp-8wv's ADR-0009 amendment).
  @spec report_recorded(
          Executions.execution_id(),
          Linkage.t(),
          {:done, term()} | {:failed, keyword()}
        ) :: :ok
  defp report_recorded(child_execution_id, %Linkage{} = linkage, {outcome, _payload}) do
    Telemetry.child_recorded(
      parent_execution_id: linkage.parent_execution_id,
      child_execution_id: child_execution_id,
      invoke_id: linkage.invoke_id,
      child_index: linkage.child_index,
      outcome: outcome
    )
  end

  @spec settlement_strategy(t()) :: {module(), term()}
  defp settlement_strategy(%__MODULE__{serialization: nil, store: store}),
    do: {AdapterLock, store}

  defp settlement_strategy(%__MODULE__{serialization: serialization}), do: serialization

  @spec settle(t(), Linkage.t(), Adapter.metadata()) ::
          {:ok, {:answer, term()} | :not_yet} | {:error, term()}
  defp settle(driver, %Linkage{} = linkage, match) do
    with {:ok, states} <- Storage.list_execution_states_by_metadata(driver.store, match),
         {:ok, states, cancelled?} <- maybe_cancel(driver, linkage, states, match) do
      decided =
        if settled?(states, linkage.child_count, cancelled?) do
          assemble(driver, linkage, states, cancelled?)
        else
          {:ok, :not_yet}
        end

      report_settled(linkage, states, decided)
      decided
    end
  end

  # `[:statifier_persistence, :child, :settled]`, once per decision this
  # section reaches and never for a read that failed before reaching one
  # (sp-8wv's ADR-0009 amendment). The four tallies are read off the same
  # `states` the decision was made from - including the cancels
  # `maybe_cancel/4` had just written, which is why this reports after the
  # decision rather than before it - and `unstarted` is the indexes with no
  # execution at all, which is the number that tells a fan-out still starting
  # from one that is stuck.
  @spec report_settled(
          Linkage.t(),
          [Adapter.execution_state()],
          {:ok, {:answer, [map()]} | :not_yet} | {:error, term()}
        ) :: :ok
  defp report_settled(%Linkage{} = linkage, states, {:ok, decision}) do
    Telemetry.child_settled(
      %{
        child_count: linkage.child_count,
        completed: Enum.count(states, &(&1.status == :completed)),
        failed: Enum.count(states, &(&1.status == :failed)),
        cancelled: Enum.count(states, &(&1.status == :cancelled)),
        unstarted: length(unstarted_indices(states, linkage.child_count))
      },
      parent_execution_id: linkage.parent_execution_id,
      invoke_id: linkage.invoke_id,
      policy: linkage.policy,
      decision: decision_atom(decision)
    )
  end

  defp report_settled(_linkage, _states, {:error, _reason}), do: :ok

  @spec decision_atom({:answer, [map()]} | :not_yet) :: :answer | :not_yet
  defp decision_atom({:answer, _entries}), do: :answer
  defp decision_atom(:not_yet), do: :not_yet

  # `first_error`'s cancel, and the whole of it: the live siblings through
  # the cascade this package already has, the not-yet-started ones through
  # the scheduler's seam. Both kinds read cancelled in the dense list that
  # follows - the started ones from their own records, the unstarted ones
  # from having none.
  #
  # It reads "any child failed" rather than "this child failed" on purpose:
  # a re-driven settlement after a crash has to reach the same conclusion
  # as the one that was interrupted.
  @spec maybe_cancel(t(), Linkage.t(), [Adapter.execution_state()], Adapter.metadata()) ::
          {:ok, [Adapter.execution_state()], boolean()} | {:error, term()}
  defp maybe_cancel(driver, %Linkage{policy: :first_error} = linkage, states, match) do
    if Enum.any?(states, &(&1.status == :failed)) do
      with {:ok, _cancelled} <-
             Executions.cascade_cancel(driver.store, match, cascade_opts(driver)),
           :ok <- cancel_unstarted(driver, linkage, states),
           {:ok, states} <- Storage.list_execution_states_by_metadata(driver.store, match) do
        {:ok, states, true}
      end
    else
      {:ok, states, false}
    end
  end

  defp maybe_cancel(_driver, _linkage, states, _match), do: {:ok, states, false}

  @spec cancel_unstarted(t(), Linkage.t(), [Adapter.execution_state()]) :: :ok | {:error, term()}
  defp cancel_unstarted(%__MODULE__{child_canceller: nil}, _linkage, _states), do: :ok

  defp cancel_unstarted(driver, %Linkage{} = linkage, states) do
    case unstarted_indices(states, linkage.child_count) do
      [] ->
        :ok

      indices ->
        case driver.child_canceller.(linkage.parent_execution_id, linkage.invoke_id, indices) do
          :ok -> :ok
          {:error, reason} -> {:error, {:child_canceller, reason}}
        end
    end
  end

  @spec unstarted_indices([Adapter.execution_state()], pos_integer()) :: [non_neg_integer()]
  defp unstarted_indices(states, child_count) do
    started = MapSet.new(states, & &1.child_index)

    Enum.reject(0..(child_count - 1), &MapSet.member?(started, &1))
  end

  # Under `:all` every one of the N indices needs an execution of its own in a
  # terminal status - an index whose start job has not run yet is an answer
  # still coming, not a missing one. Under a `first_error` cancel the
  # indices with no execution are the start jobs the scheduler was just asked to
  # cancel, so they are settled too, and they have to be or the block could
  # never answer at all.
  @spec settled?([Adapter.execution_state()], pos_integer(), boolean()) :: boolean()
  defp settled?(states, child_count, cancelled?) do
    terminal = Enum.count(states, &terminal?(&1.status))

    if cancelled? do
      terminal == length(states)
    else
      terminal == child_count
    end
  end

  @spec terminal?(Adapter.execution_status()) :: boolean()
  defp terminal?(status), do: status in [:completed, :failed, :cancelled]

  # The one materialising read of a fan-out, at its last settlement: N
  # single-key fetches over the ids `Linkage.child_execution_id/3` derives, which
  # needs no second query. The list is dense and index-ordered, so a chart
  # reads item `i`'s answer at position `i` whatever order the children
  # finished in.
  #
  # It is also the read that turns the projection's necessary condition
  # into a sufficient one (sp-kl3): an index whose answer has not been
  # recorded yet halts the whole assembly as `:not_yet`, because a fan-out
  # answers with every answer or with none.
  @spec assemble(t(), Linkage.t(), [Adapter.execution_state()], boolean()) ::
          {:ok, {:answer, [map()]} | :not_yet} | {:error, term()}
  defp assemble(driver, %Linkage{} = linkage, states, cancelled?) do
    by_index = Map.new(states, &{&1.child_index, &1})

    0..(linkage.child_count - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      case entry(driver, linkage, Map.get(by_index, index), index, cancelled?) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        :not_yet -> {:halt, :not_yet}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, {:answer, Enum.reverse(entries)}}
      :not_yet -> {:ok, :not_yet}
      {:error, _reason} = error -> error
    end
  end

  # A cancelled index answers from its status alone - it has no answer to
  # record and never will. Every other terminal index answers from its
  # recorded outcome, and `:not_yet` when that outcome is not there yet.
  @spec entry(t(), Linkage.t(), Adapter.execution_state() | nil, non_neg_integer(), boolean()) ::
          {:ok, map()} | :not_yet | {:error, term()}
  defp entry(_driver, _linkage, nil, index, true), do: {:ok, cancelled_entry(index)}

  defp entry(_driver, _linkage, %{status: :cancelled}, index, _cancelled?),
    do: {:ok, cancelled_entry(index)}

  defp entry(driver, %Linkage{} = linkage, %{status: _status}, index, _cancelled?) do
    child_execution_id =
      Linkage.child_execution_id(linkage.parent_execution_id, linkage.invoke_id, index)

    with {:ok, record} <- Storage.fetch_execution(driver.store, child_execution_id) do
      case decode_outcome(record.outcome_blob) do
        nil -> :not_yet
        outcome -> {:ok, outcome_entry(index, outcome)}
      end
    end
  end

  # String keys, because this becomes the `done.invoke` event's data and
  # every other chart-facing payload this module builds uses them
  # (`answer_event/3`). A failed entry carries st-ADR-0068's own three
  # keys, so an author reads a failed item exactly as they read a failed
  # single invocation.
  # The recorded answer, not the stored status, decides the entry's own
  # `"status"`: they are written together by `record_outcome/3`, and an
  # index with no recorded answer never reaches here (`entry/5`).
  @spec outcome_entry(non_neg_integer(), {:done, term()} | {:failed, keyword()}) :: map()
  defp outcome_entry(index, {:done, donedata}),
    do: %{"index" => index, "status" => "completed", "donedata" => donedata}

  defp outcome_entry(index, {:failed, failure}),
    do: %{"index" => index, "status" => "failed", "failure" => failure_data(failure)}

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
          Executions.execution_id(),
          {:done, term()} | {:failed, keyword()}
        ) ::
          :ok
  defp resolve_and_answer(driver, %Linkage{} = linkage, execution_id, payload) do
    with {:ok, parent_record} <-
           Storage.fetch_execution(driver.store, linkage.parent_execution_id),
         {:ok, parent_machine} <- driver.chart_resolver.(parent_record.content_hash) do
      answer_parent(%{driver | machine: parent_machine}, execution_id, payload)
    end

    :ok
  end

  # Both doors, which differ only in the answer they carry. The event is
  # built by a `t:StatifierPersistence.Executions.event_builder/0` rather than
  # here, so the liveness read and the step see one position under one
  # exclusion: a cancel cannot land between them.
  @spec reenter(
          t(),
          Executions.execution_id(),
          keyword(),
          String.t(),
          {:done, term()} | {:failed, keyword()}
        ) :: result()
  defp reenter(driver, execution_id, opts, invoke_id, answer) do
    ref = make_ref()
    opts = Keyword.put_new(opts, :entry, door(answer))
    builder = fn machine_state -> late_answer(machine_state, invoke_id, answer) end

    result =
      advance(
        driver,
        execution_id,
        opts,
        step(driver, execution_id, opts, builder, ref),
        drain(ref, []),
        0
      )

    maybe_answer_parent(driver, execution_id, result)
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
  @spec advance(
          t(),
          Executions.execution_id(),
          keyword(),
          result(),
          [answer()],
          non_neg_integer()
        ) ::
          result()
  defp advance(_driver, _execution_id, _opts, result, [], _turns), do: result

  defp advance(
         _driver,
         _execution_id,
         _opts,
         {:discarded, _execution} = result,
         _answers,
         _turns
       ),
       do: result

  defp advance(_driver, _execution_id, _opts, {:error, _reason} = result, _answers, _turns),
    do: result

  defp advance(%__MODULE__{max_turns: max_turns}, execution_id, opts, _result, _answers, turns)
       when turns >= max_turns do
    # The drive loop's own refusal, reported as a point-in-time verdict
    # rather than a span (ADR-0009 decision 5): the loop is one turn in the
    # ordinary case, so an outer pair bracketing it would almost always
    # duplicate the single step span inside it.
    Telemetry.drive_turns_exhausted(turns, execution_id: execution_id, entry: opts[:entry])

    {:error, {:turns_exhausted, max_turns}}
  end

  defp advance(
         driver,
         execution_id,
         opts,
         {:ok, _execution, machine_state} = result,
         [answer | rest],
         turns
       ) do
    if live?(machine_state, answer) do
      {_key, invoke_id, payload} = answer
      ref = make_ref()

      next =
        step(driver, execution_id, opts, answer_event(machine_state, invoke_id, payload), ref)

      advance(driver, execution_id, opts, next, rest ++ drain(ref, []), turns + 1)
    else
      # Spec 6.4.3's drain-time discard: the invocation this answer is for
      # is no longer live, so the answer is dropped rather than delivered.
      advance(driver, execution_id, opts, result, rest, turns)
    end
  end

  @spec step(
          t(),
          Executions.execution_id(),
          keyword(),
          Event.t() | Executions.event_builder(),
          reference()
        ) ::
          result()
  defp step(driver, execution_id, opts, event, ref) do
    driver.store
    |> Executions.step(execution_id, driver.machine, event, execution_opts(driver, opts, ref))
    |> fire_after_step(driver, execution_id, opts, ref)
  end

  # ADR-0008's `after_step:` amendment (2026-09-08), clauses 2 to 4, on
  # this side of the seam. Every `Executions` entry point this module calls
  # passes through here or through `create/3`, and both are reached with
  # the id of the execution that was actually stepped - the parent's, on the
  # answer path, because `answer_parent/3` reaches `reenter/5` on a driver
  # over the parent's chart and with the parent's execution id.
  #
  # The effects come back through the mailbox rather than through the
  # entry point's return value, which the amendment's clause 1 rules out
  # widening: `execution_opts/3` hands `StatifierPersistence.Executions` a
  # `step_reporter:` that sends the step's whole effect list here, tagged
  # with this drive's own reference, exactly as `buffer/4` sends a
  # dispatched invocation's answer. That is what makes the callback fire
  # from here, after the entry point has returned and outside the stepped
  # execution's exclusion, rather than from inside the persist tail.
  #
  # A drive that took no step - a discard, an error, a create the adapter
  # refused - has no message to read and fires nothing. `nil` reads no
  # mailbox at all and adds no message to it: `execution_opts/3` writes no
  # `step_reporter:` in that case, so a driver without an `after_step:`
  # takes exactly the steps and makes exactly the calls it took before
  # this option existed.
  @spec fire_after_step(result(), t(), Executions.execution_id(), keyword(), reference()) ::
          result()
  defp fire_after_step(result, driver, execution_id, opts, ref) do
    case after_step(driver, opts) do
      nil ->
        result

      after_step ->
        report(result, after_step, execution_id, drain_steps(ref, []))

        result
    end
  end

  @spec report(result(), after_step(), Executions.execution_id(), [[Statifier.Effect.t()]]) :: :ok
  defp report({:ok, _execution, machine_state}, after_step, execution_id, reported) do
    Enum.each(reported, fn effects -> after_step.(execution_id, machine_state, effects) end)
  end

  defp report(_result, _after_step, _execution_id, _reported), do: :ok

  # The driver's own default, outranked by a per-call `after_step:` in a
  # `create/3`, `send_event/4` or invocation-door `opts` list - the same
  # "the caller's opts win" shape `invoke_types:` and `serialization:`
  # already have, and the widening the amendment's closing section leaves
  # open to this bead.
  @spec after_step(t(), keyword()) :: after_step() | nil
  defp after_step(driver, opts), do: Keyword.get(opts, :after_step, driver.after_step)

  # The `step_reporter:` messages this drive's own `Executions` call left in the
  # mailbox: one per step that persisted, in the order they were sent.
  # Shaped so it can never match `drain/2`'s answers, or another drive's.
  @spec drain_steps(reference(), [[Statifier.Effect.t()]]) :: [[Statifier.Effect.t()]]
  defp drain_steps(ref, acc) do
    receive do
      {^ref, :after_step, effects} -> drain_steps(ref, [effects | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `executor:` is this module's to set, never the caller's - it is the
  # buffer the answer loop reads. Everything else is a default the caller's
  # own `opts` outrank, and `serialization:` is only written at all when
  # the driver carries one, so an unset driver falls through to
  # `StatifierPersistence.Executions`'s own default rather than overriding it
  # with `nil`.
  @spec execution_opts(t(), keyword(), reference()) :: keyword()
  defp execution_opts(driver, opts, ref) do
    after_step = after_step(driver, opts)

    opts =
      opts
      |> Keyword.delete(:after_step)
      |> Keyword.put(:executor, executor(driver, ref))
      |> Keyword.put_new(:invoke_types, driver.invoke_types)
      |> step_reporter_opt(after_step, ref)

    case driver.serialization do
      nil -> opts
      serialization -> Keyword.put_new(opts, :serialization, serialization)
    end
  end

  # `after_step:` is this module's option, not
  # `StatifierPersistence.Executions`', so it is deleted above rather than
  # passed on, and what the entry point is handed instead is the reporter
  # that carries the step's whole effect list back here. Written only when
  # a callback is actually set: without one the entry point is called with
  # exactly the options it was called with before this existed.
  @spec step_reporter_opt(keyword(), after_step() | nil, reference()) :: keyword()
  defp step_reporter_opt(execution_opts, nil, _ref), do: execution_opts

  defp step_reporter_opt(execution_opts, _after_step, ref) do
    reader = self()

    Keyword.put(execution_opts, :step_reporter, fn effects ->
      send(reader, {ref, :after_step, effects})
    end)
  end

  # The executor `StatifierPersistence.Executions` calls, once per effect, in the
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
      # `Executions.persist_tail/6`, inside `with_execution/3` - because a parent that
      # believes it has a child and a child execution that was never created is
      # the window statifier_blocks ADR-0008 decision 4 names as the one
      # that loses. The exclusion is per execution id, and a child's id is not
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
              {:failed, reason: "child_execution_creation_failed", detail: detail}
            )
        end
    end
  end

  # ADR-0008 decision 5. The core's own reaction to a state exiting while
  # one of its <invoke>s is still live - not routed through `dispatch`,
  # because cancelling a durable child is this package's own storage
  # operation and statifier_blocks ADR-0008 decision 4 says the handler
  # offers no durable counterpart to `cancel/2`. `context.execution_id` is this
  # invocation's own execution (the parent, from the cascade's point of view);
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
  # `Executions`'s own re-entry wave through `reentry_origin/1`'s existing
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
      case Executions.cascade_cancel(
             driver.store,
             Linkage.invocation_match(context.execution_id, invoke_id),
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
  # in-memory reasons), `:unidentified_chart`, `:execution_exists` from a
  # collision the adoption path will not adopt, and whatever reason
  # `create/3` or the adoption read answers with - the last two being
  # decision 4's one durable-only reason, a child execution that could not be
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
      parent_execution_id: context.execution_id,
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

  # The linkage is built from the *parent's* `context.execution_id`, this
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

    child_execution_id =
      Linkage.child_execution_id(context.execution_id, context.invoke_id, child_index)

    child_driver = %{driver | machine: child_machine}
    datamodel = Invocations.seed_datamodel(resolved.params, child_machine)

    case create(child_driver, child_execution_id,
           linkage: linkage,
           initialize: [datamodel: datamodel]
         ) do
      {:ok, _execution, machine_state} ->
        report_started(child_execution_id, linkage, child_session_id(machine_state))

      {:error, :execution_exists} ->
        adopt_child(driver.store, child_execution_id, linkage)

      {:error, reason} ->
        {:refused, reason}

      {:discarded, _execution} ->
        {:refused, :execution_exists}
    end
  end

  # `nil` is an ordinary durable subchart: index `0`, no `child_count`,
  # no policy, and a stored metadata map byte-identical to the one this
  # path has always written. A tuple is one child of a fan-out.
  @spec child_linkage(dispatch_context(), String.t(), fan_out()) ::
          {non_neg_integer(), Linkage.t()}
  defp child_linkage(context, content_hash, nil) do
    {0, Linkage.new(context.execution_id, context.invoke_id, 0, content_hash)}
  end

  defp child_linkage(context, content_hash, {index, count, policy}) do
    {index,
     Linkage.new(context.execution_id, context.invoke_id, index, content_hash, count, policy)}
  end

  # `[:statifier_persistence, :child, :started]`. Every field comes from
  # the linkage this package just wrote (ADR-0008 decision 2), which is
  # what lets the bridge link parent and child without reading
  # `StatifierPersistence.Execution.Linkage` back out of a metadata map.
  #
  # `session_id` is the child's own logical session, and it is `nil` on
  # the adoption path alone: an adopted child was created by an earlier,
  # crashed drive, so this drive has no decoded position of it and does
  # not perform a load to invent one (ADR-0009 decision 4's honest nil).
  @spec report_started(Executions.execution_id(), Linkage.t(), String.t() | nil) :: :ok
  defp report_started(child_execution_id, %Linkage{} = linkage, session_id) do
    Telemetry.child_started(
      parent_execution_id: linkage.parent_execution_id,
      child_execution_id: child_execution_id,
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

  # `{:error, :execution_exists}` is not a failure. ADR-0004 decision 3's
  # at-least-once execution means a crash between the child create and the
  # parent's own persist re-drives this exact step; the id is deterministic
  # (`Linkage.child_execution_id/3`), so the second create finds the first. A
  # collision whose linkage names this same parent and invocation is that
  # re-drive - answer `:ok` (pending) rather than refusing. A collision
  # naming something else is a genuine id clash, and is refused.
  @spec adopt_child(Storage.t(), Executions.execution_id(), Linkage.t()) ::
          :ok | {:refused, term()}
  defp adopt_child(store, child_execution_id, linkage) do
    case Storage.fetch_execution(store, child_execution_id) do
      {:ok, execution_record} ->
        case Linkage.from_metadata(execution_record.metadata) do
          {:ok, %Linkage{parent_execution_id: parent_execution_id, invoke_id: invoke_id}}
          when parent_execution_id == linkage.parent_execution_id and
                 invoke_id == linkage.invoke_id ->
            report_started(child_execution_id, linkage, nil)

          _other ->
            {:refused, :execution_exists}
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
  # for the execution's whole life (spec 5.10, st-ADR-0008), so an execution that has
  # lost it fails loudly here rather than answering with an origin no
  # `<send target>` can reach.
  @spec session_id(MachineState.t()) :: String.t()
  defp session_id(%MachineState{datamodel: %{"_sessionid" => session_id}})
       when is_binary(session_id),
       do: session_id
end
