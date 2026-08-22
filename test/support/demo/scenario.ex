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

  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.Demo.{EnrichHandler, Host, Ledger, Runtime}
  alias StatifierPersistence.Storage

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

  @spec unique_run_id() :: String.t()
  defp unique_run_id, do: "restart-demo-" <> Integer.to_string(System.unique_integer([:positive]))
end
