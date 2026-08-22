defmodule StatifierPersistence.Demo.Host do
  @moduledoc """
  A demo embedder driving a chart with no `Statifier.Session` process at
  all (`docs/plans/260822-sp-4an.4-restart-demo-host.md`, Phase 1).

  Every effect a stepped run produces reaches the outside world through
  `executor/1`'s arity-2 fun and nowhere else - reading this module top to
  bottom, nothing it does to `StatifierPersistence.Demo.Ledger` or
  `StatifierPersistence.Demo.Runtime` happens outside that one function and
  the private helpers it calls. That is what makes this host shaped like a
  real embedder rather than a test harness with effects inlined.

  A `%Host{}` carries no `Statifier.MachineState.t()` of its own between
  calls - the durable position lives in `store`, loaded fresh by
  `StatifierPersistence.Runs` on every `submit/3`/`finish_invocation/4`/
  `tick/2`, exactly as a stateless embedder process would. `machine` is the
  one piece of compiled, in-memory state a host does keep around: a
  `Statifier.Machine.t()` is a pure compiled artifact, not a position, and
  re-deriving it from the stored chart is `boot/4`'s job, not every step's.
  """

  alias Statifier.{Chart, Event, Machine, MachineState}
  alias Statifier.Effect.{Cancel, CancelInvoke, Invoke, Send, SendDelayed}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Send.Routes
  alias StatifierPersistence.Demo.{Ledger, Runtime}
  alias StatifierPersistence.{Run, Runs, Storage}

  @enforce_keys [:store, :ledger, :runtime, :machine, :run_id]
  defstruct [
    :store,
    :ledger,
    :runtime,
    :machine,
    :run_id,
    :run,
    invoke_handlers: %{},
    invoke_types: nil,
    tape: []
  ]

  @type t :: %__MODULE__{
          store: Storage.t(),
          ledger: Ledger.t(),
          runtime: Runtime.t(),
          machine: Machine.t(),
          run_id: Runs.run_id(),
          run: Run.t() | nil,
          invoke_handlers: %{String.t() => module()},
          invoke_types: Statifier.Invoke.Types.t() | nil,
          tape: [Event.t()]
        }

  @doc """
  Cold-boots from `run_id` alone: `Storage.fetch_run/2` for the content
  hash, `Storage.fetch_chart/2` for the stored blob, `Chart.from_binary/1`
  to recompile a **freshly interned** `%Machine{}` - never the pre-restart
  struct, which is what makes the identity guard on the next step exercise
  something real (`Statifier.Chart.to_binary/1`'s moduledoc; the plan's Key
  Discoveries).

  Records a `{:chart_fetched, content_hash}` marker on the ledger's own
  side-effect log every time it runs, so a test can assert that a
  post-restart boot really re-read the chart rather than reusing a carried
  struct.

  `invoke_handlers:`/`invoke_types:` are **not** restored here - like
  `routes`/`invoke_types` on a decoded `MachineState` (st-ADR-0064), the
  handler palette is a per-deployment declaration, not durable state, and a
  caller re-supplies it (`%{host | invoke_handlers: ..., invoke_types: ...}`)
  before driving the rebuilt host.
  """
  @spec boot(Storage.t(), Ledger.t(), Runtime.t(), Runs.run_id()) ::
          {:ok, t()} | {:error, term()}
  def boot(%Storage{} = store, ledger, runtime, run_id) do
    with {:ok, run_record} <- Storage.fetch_run(store, run_id),
         {:ok, chart_record} <- Storage.fetch_chart(store, run_record.content_hash),
         {:ok, machine} <- Chart.from_binary(chart_record.chart_blob) do
      :ok = Ledger.record_side_effect(ledger, {:chart_fetched, run_record.content_hash})

      {:ok,
       %__MODULE__{
         store: store,
         ledger: ledger,
         runtime: runtime,
         machine: machine,
         run_id: run_id,
         run: Run.from_record(run_record)
       }}
    end
  end

  @doc """
  The very-first-boot path, for a `run_id` with no stored run yet: compiles
  `source` fresh, `Storage.save_chart/3`s its `Chart.to_binary/1` blob, then
  `Runs.create/4` through this host's own `executor/1` - so even the
  creation step's effects (an onentry `<send delay>`, an onentry `<invoke>`)
  cross the same seam every later step does.

  `opts` accepts `invoke_handlers:` (default `%{}`) and `invoke_types:`
  (default `nil`), the palette this run's every future step is driven with.
  """
  @spec start_run(Storage.t(), Ledger.t(), Runtime.t(), Runs.run_id(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def start_run(%Storage{} = store, ledger, runtime, run_id, source, opts \\ [])
      when is_binary(source) do
    invoke_handlers = Keyword.get(opts, :invoke_handlers, %{})
    invoke_types = Keyword.get(opts, :invoke_types)

    with {:ok, machine} <- Statifier.compile(source),
         {:ok, chart_blob} <- Chart.to_binary(machine),
         :ok <- Storage.save_chart(store, machine, chart_blob) do
      host = %__MODULE__{
        store: store,
        ledger: ledger,
        runtime: runtime,
        machine: machine,
        run_id: run_id,
        run: nil,
        invoke_handlers: invoke_handlers,
        invoke_types: invoke_types,
        tape: []
      }

      case Runs.create(store, run_id, machine,
             executor: executor(host),
             invoke_types: invoke_types
           ) do
        {:ok, run, _machine_state} -> {:ok, %{host | run: run}}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  The seam: an arity-2 fun `StatifierPersistence.Runs` calls once per
  effect. Every call is recorded onto the ledger's executor call log first,
  unconditionally, then dispatched per the effect table below - so the log
  is complete even for an effect the dispatch itself goes on to fail.

  | effect | host action |
  |---|---|
  | `{:send_delayed, _}` | `Ledger.arm_timer/3` (durable, idempotent on `{run_id, ordinal}`), then `Runtime.arm/3` |
  | `{:cancel, _}` | `Ledger.cancel_timer/3` by `{run_id, send_id}`, then `Runtime.disarm/2` for each row it removed |
  | `{:invoke, _}` | look `type` up in `invoke_handlers`; `handler.start/2`; perform the instructions (`Ledger.record_invocation/3` + `Runtime.start_worker/3`) |
  | `{:cancel_invoke, _}` | the ledger's own recorded `type` for `invoke_id` finds the handler; `handler.cancel/2`; perform (`Ledger.close_invocation/3` + `Runtime.stop_worker/2`) |
  | `{:send, _}` | `Ledger.record_side_effect/2` only - nothing external to reach in a demo |
  | everything else (`:log`, `:datamodel_change`, `:datamodel_init`, `:trace`, `:autoforward`) | `:ok`, observational |

  An `{:invoke, _}` or `{:cancel_invoke, _}` whose type resolves to no
  registered handler returns `{:error, {:no_handler, type}}` - unreachable
  on this chart's happy path, but the seam stays honest rather than
  silently succeeding.
  """
  @spec executor(t()) :: StatifierPersistence.Executor.t()
  def executor(%__MODULE__{} = host) do
    fn effect, context ->
      :ok = Ledger.record_call(host.ledger, effect, context)
      handle_effect(host, effect)
    end
  end

  @spec handle_effect(t(), Statifier.Effect.t()) :: :ok | {:error, term()}
  defp handle_effect(host, {:send_delayed, %SendDelayed{} = payload}) do
    due_at_ms = Runtime.now_ms(host.runtime) + payload.delay_ms

    row = %{
      send_id: payload.send_id,
      event: payload.event,
      data: payload.data,
      due_at_ms: due_at_ms,
      ordinal: payload.ordinal
    }

    :ok = Ledger.arm_timer(host.ledger, host.run_id, row)
    :ok = Runtime.arm(host.runtime, payload.ordinal, due_at_ms)
    :ok
  end

  defp handle_effect(host, {:cancel, %Cancel{send_id: send_id}}) do
    host.ledger
    |> Ledger.cancel_timer(host.run_id, send_id)
    |> Enum.each(&Runtime.disarm(host.runtime, &1))

    :ok
  end

  defp handle_effect(host, {:invoke, %Invoke{type: type} = invoke}) do
    case Map.fetch(host.invoke_handlers, type) do
      {:ok, handler} ->
        {:ok, instructions} = handler.start(invoke, handler_ctx(host))
        Enum.each(instructions, &perform_instruction(host, type, &1))
        :ok

      :error ->
        {:error, {:no_handler, type}}
    end
  end

  defp handle_effect(host, {:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}}) do
    type = invocation_type(host, invoke_id)

    case Map.fetch(host.invoke_handlers, type) do
      {:ok, handler} ->
        {:ok, instructions} = handler.cancel(invoke_id, handler_ctx(host))
        Enum.each(instructions, &perform_instruction(host, type, &1))
        :ok

      :error ->
        {:error, {:no_handler, type}}
    end
  end

  defp handle_effect(host, {:send, %Send{} = payload}) do
    Ledger.record_side_effect(host.ledger, {:send, payload})
  end

  defp handle_effect(_host, _observational_effect), do: :ok

  @spec handler_ctx(t()) :: Statifier.Invoke.Handler.ctx()
  defp handler_ctx(host) do
    %{
      session_id: host.run_id,
      invoke_types: host.invoke_types,
      invoke_handlers: host.invoke_handlers
    }
  end

  # The recorded type for an open invocation, so `{:cancel_invoke, _}` -
  # which carries no `type` field itself - can still find its handler.
  @spec invocation_type(t(), String.t()) :: String.t() | nil
  defp invocation_type(host, invoke_id) do
    host.ledger
    |> Ledger.open_invocations(host.run_id)
    |> Enum.find_value(fn row -> row.invoke_id == invoke_id and row.type end)
  end

  @spec perform_instruction(t(), String.t() | nil, Statifier.Invoke.Handler.instruction()) :: :ok
  defp perform_instruction(host, type, {:handler, _module, {:start, invoke_id, params}}) do
    :ok =
      Ledger.record_invocation(host.ledger, host.run_id, %{
        invoke_id: invoke_id,
        type: type,
        params: params
      })

    _worker_pid = Runtime.start_worker(host.runtime, invoke_id, params)
    :ok
  end

  defp perform_instruction(host, _type, {:handler, _module, {:cancel, invoke_id}}) do
    :ok = Ledger.close_invocation(host.ledger, host.run_id, invoke_id)
    Runtime.stop_worker(host.runtime, invoke_id)
  end

  @doc """
  Appends `Event.external(event_name, event_opts)` to `tape`, then
  `Runs.step/5`. Handles all three result arms: `{:discarded, run}` is
  recorded onto `run`, not raised - an event delivered to a run that went
  terminal on a prior step is exactly what a durable host must tolerate.
  """
  @spec submit(t(), String.t(), keyword()) :: t()
  def submit(%__MODULE__{} = host, event_name, event_opts \\ []) do
    submit_event(host, Event.external(event_name, event_opts))
  end

  @doc """
  Builds the `done.invoke.<invoke_id>` event in the exact shape
  `deps/statifier/lib/statifier/session.ex`'s own construction site builds
  it (the shape `docs/extending.md` documents for a process-less host to
  match) and submits it. `run_id` stands in for `session_id` - this host has
  no session, only a run.
  """
  @spec finish_invocation(t(), String.t(), term(), keyword()) :: t()
  def finish_invocation(%__MODULE__{} = host, invoke_id, donedata, _opts \\ []) do
    event =
      Event.external("done.invoke." <> invoke_id,
        data: donedata,
        invokeid: invoke_id,
        origin: SystemVariables.scxml_location(host.run_id),
        origintype: SystemVariables.scxml_event_processor()
      )

    submit_event(host, event)
  end

  @doc """
  Advances the mock clock by `delta_ms`. For each ordinal `Runtime.due/2`
  reports, loads that timer's row from the ledger, submits its event, and
  drops the durable row - after the step returns, so a step that discards
  (a terminal run) still drops the row without having driven the chart at
  all (`deps/statifier/docs/durable-timers.md:286`'s liveness rule; `Runs`
  itself checks run status before any position decode).
  """
  @spec tick(t(), non_neg_integer()) :: t()
  def tick(%__MODULE__{} = host, delta_ms) do
    host.runtime
    |> Runtime.due(delta_ms)
    |> Enum.reduce(host, fn ordinal, host -> fire_timer(host, ordinal) end)
  end

  @spec fire_timer(t(), Runtime.ordinal()) :: t()
  defp fire_timer(host, ordinal) do
    host =
      case timer_row(host, ordinal) do
        nil -> host
        row -> submit_event(host, Event.external(row.event, sendid: row.send_id, data: row.data))
      end

    :ok = Ledger.drop_timer(host.ledger, host.run_id, ordinal)
    host
  end

  @spec timer_row(t(), Runtime.ordinal()) :: Ledger.timer_row() | nil
  defp timer_row(host, ordinal) do
    host.ledger
    |> Ledger.open_timers(host.run_id)
    |> Enum.find(&(&1.ordinal == ordinal))
  end

  @spec submit_event(t(), Event.t()) :: t()
  defp submit_event(host, event) do
    host = %{host | tape: host.tape ++ [event]}

    case Runs.step(host.store, host.run_id, host.machine, event,
           executor: executor(host),
           invoke_types: host.invoke_types,
           routes: Routes.new()
         ) do
      {:ok, run, _machine_state} -> %{host | run: run}
      {:discarded, run} -> %{host | run: run}
    end
  end

  @doc "The last-observed run record - `nil` before `start_run/6`/`boot/4`."
  @spec run(t()) :: Run.t() | nil
  def run(%__MODULE__{run: run}), do: run

  @doc "The current durable position, reloaded from `store` (never cached on the struct)."
  @spec position(t()) :: {:ok, MachineState.t()} | {:error, term()}
  def position(%__MODULE__{} = host),
    do: Storage.load_run_position(host.store, host.run_id, host.machine)

  @doc "The active leaf states as sorted string ids - `runs_test.exs`'s `active_ids/1` shape, off the durable position."
  @spec config(t()) :: [String.t()]
  def config(%__MODULE__{} = host) do
    {:ok, machine_state} = position(host)

    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  @doc "Every event submitted so far, oldest first - the input tape a replay drives."
  @spec tape(t()) :: [Event.t()]
  def tape(%__MODULE__{tape: tape}), do: tape
end
