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

  `<invoke type="scxml">` is handed to `:dispatch` like any other type,
  and this module has no opinion about it. A durable driver holds no child
  session between steps, so a subchart is the host's to answer or refuse;
  durable subcharts are deliberately out of scope here (campaign-023
  ruling R-e).

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

  alias Statifier.Effect.Invoke
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.{Event, Machine, MachineState}
  alias StatifierPersistence.{Executor, Run, Runs, Storage}

  @typedoc """
  Performs one `<invoke>` and answers it, synchronously, inside the durable
  step that emitted it.

  Receives the element's own `type` and resolved `params`
  (`t:Statifier.Effect.Invoke.t/0`'s fields) plus the executor's context -
  the run id and the chart's content hash. `{:ok, donedata}` answers
  `done.invoke.<invoke_id>` with `donedata`; `{:error, failure}` answers
  `error.communication.invoke.<invoke_id>` with st-ADR-0068's `failure`
  keyword list (`:reason`, `:attempts`, `:detail`), and means permanently
  failed, not "try again".
  """
  @type dispatch ::
          (type :: String.t() | nil, params :: term(), context :: Executor.context() ->
             {:ok, term()} | {:error, keyword()})

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

  @enforce_keys [:store, :machine, :dispatch]
  defstruct [
    :store,
    :machine,
    :dispatch,
    :effects,
    :invoke_types,
    :serialization,
    max_turns: 1_000
  ]

  @type t :: %__MODULE__{
          store: Storage.t(),
          machine: Machine.t(),
          dispatch: dispatch(),
          effects: Executor.t() | nil,
          invoke_types: MachineState.invoke_types(),
          serialization: {module(), term()} | nil,
          max_turns: pos_integer()
        }

  # One buffered answer: the invocation's `{state_index, invoke_index}`
  # liveness key, its id, and what the host answered with.
  @typep answer ::
           {{non_neg_integer(), non_neg_integer()}, String.t(),
            {:done, term()} | {:failed, keyword()}}

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
    opts = create_opts(driver, opts)
    result = Runs.create(driver.store, run_id, driver.machine, run_opts(driver, opts, ref))

    advance(driver, run_id, opts, result, drain(ref, []), 0)
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
    result = step(driver, run_id, opts, event, ref)

    advance(driver, run_id, opts, result, drain(ref, []), 0)
  end

  # The loop of the moduledoc's steps 4 and 5. `result` is carried rather
  # than rebuilt because it is what the drive returns: a discarded answer
  # leaves the previous step's result standing, unchanged.
  @spec advance(t(), Runs.run_id(), keyword(), result(), [answer()], non_neg_integer()) ::
          result()
  defp advance(_driver, _run_id, _opts, result, [], _turns), do: result

  defp advance(_driver, _run_id, _opts, {:discarded, _run} = result, _answers, _turns), do: result

  defp advance(_driver, _run_id, _opts, {:error, _reason} = result, _answers, _turns), do: result

  defp advance(%__MODULE__{max_turns: max_turns}, _run_id, _opts, _result, _answers, turns)
       when turns >= max_turns,
       do: {:error, {:turns_exhausted, max_turns}}

  defp advance(driver, run_id, opts, {:ok, _run, machine_state} = result, [answer | rest], turns) do
    if live?(machine_state, answer) do
      ref = make_ref()
      next = step(driver, run_id, opts, answer_event(machine_state, answer), ref)

      advance(driver, run_id, opts, next, rest ++ drain(ref, []), turns + 1)
    else
      # Spec 6.4.3's drain-time discard: the invocation this answer is for
      # is no longer live, so the answer is dropped rather than delivered.
      advance(driver, run_id, opts, result, rest, turns)
    end
  end

  @spec step(t(), Runs.run_id(), keyword(), Event.t(), reference()) :: result()
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
    effects = driver.effects
    dispatch = driver.dispatch

    fn effect, context ->
      with :ok <- observe(effects, effect, context) do
        perform(dispatch, effect, context, reader, ref)
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
  @spec perform(dispatch(), Statifier.Effect.t(), Executor.context(), pid(), reference()) :: :ok
  defp perform(dispatch, {:invoke, %Invoke{} = invoke}, context, reader, ref) do
    answer =
      case dispatch.(invoke.type, invoke.params, context) do
        {:ok, donedata} -> {:done, donedata}
        {:error, failure} -> {:failed, failure}
      end

    send(reader, {ref, {invoke.state_index, invoke.invoke_index}, invoke.invoke_id, answer})

    :ok
  end

  defp perform(_dispatch, _effect, _context, _reader, _ref), do: :ok

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
  @spec answer_event(MachineState.t(), answer()) :: Event.t()
  defp answer_event(machine_state, {_key, invoke_id, {:done, donedata}}) do
    invoked_event(machine_state, "done.invoke." <> invoke_id, invoke_id, donedata)
  end

  defp answer_event(machine_state, {_key, invoke_id, {:failed, failure}}) when is_list(failure) do
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
