defmodule StatifierPersistence.Demo.Scenario do
  @moduledoc """
  The demo chart and the scenario body that drives it
  (`docs/plans/260822-sp-4an.4-restart-demo-host.md`), parameterized on a
  `{adapter, opts}` storage pair so the same body runs unchanged against
  `StatifierPersistence.Storage.InMemory` (Phase 1-3) and
  `StatifierPersistence.Storage.Ecto` (Phase 4).

  The chart, probe-verified end to end before this plan was written (see
  the plan's Key Discoveries): `intake` submits into `enriching`, which
  arms a 900s `sla-timer` and starts an async `myapp:enrich` invocation in
  parallel; `done.invoke.enrich` moves to `cooling`, which arms a 3600s
  `reminder-timer`; the still-armed `sla-timer` (never explicitly
  cancelled - only `<invoke>` exit-cancels, never a plain `<send>`) fires
  `sla.breach` from inside `cooling`, cancelling `reminder-timer` on the
  way to `settling`; `ack` reaches the top-level final `settled`. `escalated`
  is the negative target: reaching it means the demo lost the race it
  exists to control.
  """

  alias Statifier.{Event, Machine, MachineState}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Send.Routes
  alias StatifierPersistence.Demo.{EnrichHandler, Host, Ledger, Runtime}
  alias StatifierPersistence.{Runs, Storage}

  @chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="intake">
    <state id="intake">
      <transition event="submit" target="enriching"/>
    </state>

    <state id="enriching">
      <onentry>
        <send event="sla.breach" id="sla-timer" delay="900s"/>
      </onentry>
      <invoke type="myapp:enrich" id="enrich"/>
      <transition event="done.invoke.enrich" target="cooling"/>
      <transition event="sla.breach" target="escalated"/>
    </state>

    <state id="cooling">
      <onentry>
        <send event="reminder" id="reminder-timer" delay="3600s"/>
      </onentry>
      <transition event="sla.breach" target="settling">
        <cancel sendid="reminder-timer"/>
      </transition>
      <transition event="reminder" target="escalated"/>
    </state>

    <state id="settling">
      <transition event="ack" target="settled"/>
    </state>

    <final id="settled"/>
    <state id="escalated"/>
  </scxml>
  """

  @doc "The chart's raw SCXML source."
  @spec source() :: String.t()
  def source, do: @chart_source

  @doc "The chart, compiled once. Raises on a compile failure - the source is probe-verified."
  @spec machine!() :: Statifier.Machine.t()
  def machine! do
    {:ok, machine} = Statifier.compile(@chart_source)
    machine
  end

  @doc "The registered-types snapshot every step in this scenario stamps."
  @spec invoke_types() :: InvokeTypes.t()
  def invoke_types, do: InvokeTypes.new(types: ["myapp:enrich"])

  @doc "The handler palette every step in this scenario stamps."
  @spec handlers() :: %{String.t() => module()}
  def handlers, do: %{"myapp:enrich" => EnrichHandler}

  @doc """
  Drives the chart straight through, with no restart: `submit` ->
  `finish_invocation` -> a `tick` long enough for the still-armed
  `sla-timer` to fire -> `ack`. Returns a map with the final `Host.t()`,
  the ledger and runtime it ran against (for a caller that wants to inspect
  them directly), and the leaf-id configuration observed after each of the
  three non-terminal steps, in order.

  `{adapter, opts}` is handed straight to `Storage.new/2`, unchanged - this
  function names no storage module itself, which is what lets Phase 4 run
  it again against `Storage.Ecto` with no edit here.
  """
  @spec straight_through({module(), keyword()}) :: %{
          host: Host.t(),
          ledger: Ledger.t(),
          runtime: Runtime.t(),
          configs: [[String.t()]]
        }
  def straight_through({adapter, opts}) do
    run_id = unique_run_id()
    {:ok, store} = Storage.new(adapter, opts)
    {:ok, ledger} = Ledger.start_link([])
    {:ok, runtime} = Runtime.start_link([])

    {:ok, host} =
      Host.start_run(store, ledger, runtime, run_id, @chart_source,
        invoke_handlers: handlers(),
        invoke_types: invoke_types()
      )

    host = Host.submit(host, "submit")
    after_submit = Host.config(host)

    host = Host.finish_invocation(host, "enrich", %{"score" => 7})
    after_finish = Host.config(host)

    # Long enough for the still-armed 900s sla-timer to fire; short of the
    # 3600s reminder-timer cooling armed, which must never fire.
    host = Host.tick(host, :timer.minutes(20))
    after_tick = Host.config(host)

    host = Host.submit(host, "ack")

    %{
      host: host,
      ledger: ledger,
      runtime: runtime,
      configs: [after_submit, after_finish, after_tick]
    }
  end

  @doc """
  Drives the chart to the kill point (`enriching`, `sla-timer` pending,
  `enrich` in flight), stops the volatile runtime to simulate the node
  dying, cold-boots a fresh `Host.t()` from `run_id` alone, `recover/1`s
  it, then drives the rest of the chart to `:completed` exactly as
  `straight_through/1` does after its own kill point.

  Returns a map carrying every value the restart test needs to assert at
  each stage: the host and its pre-restart worker pid at the kill point,
  the rebuilt host after `boot/4` and again after `recover/1`, the final
  host, the ledger (shared across the restart - it is the durable layer),
  and the leaf-id configuration observed after each non-terminal step.

  `{adapter, opts}` is the same pass-through `straight_through/1` takes.
  """
  @spec across_restart({module(), keyword()}) :: %{
          host_at_kill: Host.t(),
          config_at_kill: [String.t()],
          open_timers_at_kill: [Ledger.timer_row()],
          open_invocations_at_kill: [Ledger.invocation_row()],
          active_invocations_at_kill: non_neg_integer(),
          pid_before: pid(),
          alive_before_stop: boolean(),
          alive_after_stop: boolean(),
          armed_before_stop: MapSet.t(pos_integer()),
          host_after_boot: Host.t(),
          armed_after_boot: MapSet.t(pos_integer()),
          host_after_recover: Host.t(),
          pid_after_recover: pid() | nil,
          alive_after_recover: boolean(),
          open_timers_after_recover: [Ledger.timer_row()],
          host: Host.t(),
          ledger: Ledger.t(),
          run_id: String.t(),
          configs: [[String.t()]]
        }
  def across_restart({adapter, opts}) do
    run_id = unique_run_id()
    {:ok, store} = Storage.new(adapter, opts)
    {:ok, ledger} = Ledger.start_link([])
    {:ok, runtime} = Runtime.start_link([])

    {:ok, host} =
      Host.start_run(store, ledger, runtime, run_id, @chart_source,
        invoke_handlers: handlers(),
        invoke_types: invoke_types()
      )

    host_at_kill = Host.submit(host, "submit")

    # `Host.position/1`/`Host.config/1` and the ledger's `open_*` readers
    # always reflect the *current* store/ledger state, never a cached
    # snapshot (`Host.position/1`'s own moduledoc) - so every kill-point
    # observation the test wants to make must be captured here, before the
    # scenario drives any further step, not read back off `host_at_kill`
    # once this function has returned.
    config_at_kill = Host.config(host_at_kill)
    open_timers_at_kill = Ledger.open_timers(ledger, run_id)
    open_invocations_at_kill = Ledger.open_invocations(ledger, run_id)
    {:ok, machine_state_at_kill} = Host.position(host_at_kill)
    active_invocations_at_kill = map_size(machine_state_at_kill.active_invocations)

    pid_before = Runtime.worker(host_at_kill.runtime, "enrich")
    alive_before_stop = Process.alive?(pid_before)
    armed_before_stop = Runtime.armed(host_at_kill.runtime)

    # The node dies: every volatile pid this runtime owns, timers and
    # workers alike, goes with it. `Process.alive?(pid_before)` after this
    # point is captured here too - the scenario runs to completion inside
    # one call, so a caller that checked it against the returned pid only
    # after `across_restart/1` returns would always see the post-restart
    # world, same reason `config_at_kill` above is captured rather than
    # re-derived from `host_at_kill`.
    :ok = Runtime.stop(host_at_kill.runtime)
    alive_after_stop = Process.alive?(pid_before)

    {:ok, new_runtime} = Runtime.start_link([])
    {:ok, host_after_boot} = Host.boot(store, ledger, new_runtime, run_id)

    host_after_boot = %{
      host_after_boot
      | invoke_handlers: handlers(),
        invoke_types: invoke_types()
    }

    # Captured before `recover/1` runs, on the same fresh runtime pid
    # `host_after_recover` below goes on to arm - proving `boot/4` alone
    # restores nothing volatile.
    armed_after_boot = Runtime.armed(host_after_boot.runtime)

    host_after_recover = Host.recover(host_after_boot)
    pid_after_recover = Runtime.worker(host_after_recover.runtime, "enrich")
    # Captured now, before `finish_invocation/4` below cancel-stops this
    # very worker as part of driving the tail - same reason every other
    # "as of this moment" field here is captured eagerly.
    alive_after_recover = pid_after_recover != nil and Process.alive?(pid_after_recover)
    open_timers_after_recover = Ledger.open_timers(ledger, run_id)

    host = Host.finish_invocation(host_after_recover, "enrich", %{"score" => 7})
    after_finish = Host.config(host)

    # Long enough for the still-armed 900s sla-timer to fire; short of the
    # 3600s reminder-timer cooling armed after the restart, which must
    # never fire.
    host = Host.tick(host, :timer.minutes(20))
    after_tick = Host.config(host)

    host = Host.submit(host, "ack")

    %{
      host_at_kill: host_at_kill,
      config_at_kill: config_at_kill,
      open_timers_at_kill: open_timers_at_kill,
      open_invocations_at_kill: open_invocations_at_kill,
      active_invocations_at_kill: active_invocations_at_kill,
      pid_before: pid_before,
      alive_before_stop: alive_before_stop,
      alive_after_stop: alive_after_stop,
      armed_before_stop: armed_before_stop,
      host_after_boot: host_after_boot,
      armed_after_boot: armed_after_boot,
      host_after_recover: host_after_recover,
      pid_after_recover: pid_after_recover,
      alive_after_recover: alive_after_recover,
      open_timers_after_recover: open_timers_after_recover,
      host: host,
      ledger: ledger,
      run_id: run_id,
      configs: [after_finish, after_tick]
    }
  end

  @spec unique_run_id() :: String.t()
  defp unique_run_id, do: "restart-demo-" <> Integer.to_string(System.unique_integer([:positive]))
end
