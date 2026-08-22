defmodule StatifierPersistence.Demo.RestartDemoEctoTest do
  @moduledoc """
  The demo scenarios re-run against `StatifierPersistence.Storage.Ecto`
  over real Postgres (the ADR-0005 harness), so the demo proves the loop,
  not the `InMemory` adapter (Phase 4 of
  `docs/plans/260822-sp-4an.4-restart-demo-host.md`).

  The per-stage assertions live in `StatifierPersistence.Demo.RestartDemoTest`;
  this variant drives the identical scenario bodies (`Scenario` names no
  storage module) and asserts the same outcomes, plus the one thing only
  this variant can prove - that the post-restart boot re-read the chart
  and the run from the database, under the default `AdapterLock`
  serialization's advisory-plus-row lock on every step.

  `async: false` per the plan: the demo drives several `Storage.new/2`
  handles in one test over a single sandbox-checked-out connection.
  """
  use ExUnit.Case, async: false

  alias Statifier.Effect.{Cancel, CancelInvoke, DatamodelInit, Invoke, SendDelayed}
  alias StatifierPersistence.Demo.{Host, Ledger, Scenario}
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Run
  alias StatifierPersistence.Storage

  @adapter Storage.Ecto
  @adapter_opts [persistence: EctoHosts.Default, sandbox: true]

  setup do
    # The conformance suite's shape: normalize the opts through
    # `Storage.new/2`, then check this test process out its own sandboxed
    # connection/transaction.
    {:ok, store} = Storage.new(@adapter, @adapter_opts)
    :ok = @adapter.isolate(store.opts)
    :ok
  end

  # Sabotage notes: the scenario bodies and the mutations are shared with
  # the InMemory variant - see the notes on `RestartDemoTest`'s tests
  # (Runs.run_status/2, Runs.write_run/6, Storage.load_run_position/3).
  # Those mutations were each run and confirmed red there; the scenario
  # body being shared is what carries the coverage here (the plan's
  # Testing Strategy table records this explicitly).

  test "drives the chart straight through over Postgres" do
    result = Scenario.straight_through({@adapter, @adapter_opts})

    assert result.configs == [["enriching"], ["cooling"], ["settling"]]
    refute Enum.any?(result.configs, &("escalated" in &1))
    assert %Run{status: :completed} = Host.run(result.host)

    calls = result.ledger |> Ledger.calls() |> Enum.map(fn {effect, _context} -> effect end)

    assert [
             {:datamodel_init, %DatamodelInit{}},
             {:send_delayed, %SendDelayed{send_id: "sla-timer", event: "sla.breach"}},
             {:invoke, %Invoke{type: "myapp:enrich", invoke_id: invoke_id}},
             {:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}},
             {:send_delayed, %SendDelayed{send_id: "reminder-timer", event: "reminder"}},
             {:cancel, %Cancel{send_id: "reminder-timer"}}
           ] = calls
  end

  test "resumes from a simulated restart over Postgres" do
    result = Scenario.across_restart({@adapter, @adapter_opts})

    # Kill point, node death, and re-established liveness - same claims
    # the InMemory variant pins in full.
    assert result.config_at_kill == ["enriching"]
    refute result.alive_after_stop
    assert is_pid(result.pid_after_recover)
    refute result.pid_after_recover == result.pid_before

    # The post-restart boot genuinely re-read from Postgres: the
    # `{:chart_fetched, _}` marker is present, and the freshly recompiled
    # machine's identity matches the stored run record's - this is the
    # plan's "confirm `boot/4` issues a `fetch_run` and a `fetch_chart`"
    # check, asserted rather than observed by hand.
    assert {:chart_fetched, content_hash} =
             result.ledger
             |> Ledger.side_effects()
             |> Enum.find(&match?({:chart_fetched, _}, &1))

    assert content_hash == result.host_after_boot.machine.identity.content_hash
    assert %Run{content_hash: ^content_hash} = Host.run(result.host_after_boot)

    # The tail finishes with the exact same executor call log - nothing
    # re-emitted across the restart, now with every step's write behind
    # `Storage.Ecto.lock_run/3`.
    assert result.configs == [["cooling"], ["settling"]]
    assert %Run{status: :completed} = Host.run(result.host)

    calls = result.ledger |> Ledger.calls() |> Enum.map(fn {effect, _context} -> effect end)

    assert [
             {:datamodel_init, %DatamodelInit{}},
             {:send_delayed, %SendDelayed{send_id: "sla-timer", event: "sla.breach"}},
             {:invoke, %Invoke{type: "myapp:enrich", invoke_id: invoke_id}},
             {:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}},
             {:send_delayed, %SendDelayed{send_id: "reminder-timer", event: "reminder"}},
             {:cancel, %Cancel{send_id: "reminder-timer"}}
           ] = calls
  end

  test "replays the recorded tape over Postgres" do
    result = Scenario.across_restart({@adapter, @adapter_opts})

    {:ok, replay_store} = Storage.new(@adapter, @adapter_opts)
    {:ok, replay_ledger} = Ledger.start_link([])
    replay_run_id = "restart-demo-replay-#{System.unique_integer([:positive])}"

    # Same recorded-inputs discipline as the InMemory variant: the session
    # id is the one generated create input, re-supplied to the replay.
    {:ok, final_position} = Host.position(result.host)
    original_session_id = final_position.datamodel["_sessionid"]

    replay_result =
      Scenario.replay(Host.tape(result.host), {replay_store, replay_ledger}, replay_run_id,
        initialize: [session_id: original_session_id]
      )

    original_configs = [result.config_at_kill] ++ result.configs ++ [Host.config(result.host)]
    assert Enum.drop(replay_result.configs, 1) == original_configs

    original_effects =
      result.ledger |> Ledger.calls() |> Enum.map(fn {effect, _context} -> effect end)

    assert replay_result.effects == original_effects
  end
end
