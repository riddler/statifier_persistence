defmodule StatifierPersistence.Demo.RestartDemoTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.{Cancel, CancelInvoke, DatamodelInit, Invoke, SendDelayed}
  alias StatifierPersistence.Demo.{Host, Ledger, Scenario}
  alias StatifierPersistence.Run
  alias StatifierPersistence.Storage.InMemory

  # sabotage: Runs.run_status/2 (runs.ex ~465-471) changed from
  # `machine_state.status == :done -> :completed` to `-> :active` -> red
  # (the `status: :completed` assertion below fails: `Host.run(host).status`
  # comes back `:active`). Reverted and confirmed green.
  test "drives the chart straight through, with no restart, to :completed" do
    result = Scenario.straight_through({InMemory, []})

    # The configuration path after each non-terminal step, in order:
    # intake -> enriching -> cooling -> settling. `escalated` - the
    # negative target reached only if the demo lost the race it exists to
    # control - is never among them.
    assert result.configs == [["enriching"], ["cooling"], ["settling"]]
    refute Enum.any?(result.configs, &("escalated" in &1))

    assert %Run{status: :completed} = Host.run(result.host)

    # The exact executor call log: the create-time `:datamodel_init`
    # baseline, one send_delayed per armed timer, one invoke, one
    # cancel_invoke on the invocation's exit, and one cancel of the
    # reminder-timer the still-armed sla-timer's fire drives - nothing
    # executed twice, and `:done` never reaches the executor at all (the
    # lifecycle consumes it before the seam).
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

  # sabotage: Runs.write_run/6 (runs.ex ~512-525) changed so the `:update`
  # write path passes `position: :skip` unconditionally -> red. Every
  # post-create step (`step_tail/6` reloads the position from storage on
  # every call) then persists nothing, so the stored blob never leaves
  # `intake`: this test's very first assertion, `config_at_kill ==
  # ["enriching"]`, fails immediately (left: `["intake"]`). Confirmed by
  # actually running the mutation - it also fails the straight-through
  # test the same way, but this test's own kill-point assertion is
  # sufficient to make it red on its own. Reverted and confirmed green.
  test "resumes from a simulated restart with no duplicate side effects" do
    result = Scenario.across_restart({InMemory, []})

    # --- at the kill point ---
    assert result.config_at_kill == ["enriching"]
    assert [%{send_id: "sla-timer"}] = result.open_timers_at_kill
    assert [%{invoke_id: "enrich", type: "myapp:enrich"}] = result.open_invocations_at_kill
    assert result.active_invocations_at_kill == 1

    assert is_pid(result.pid_before)
    assert result.alive_before_stop
    assert MapSet.size(result.armed_before_stop) == 1

    # --- after Runtime.stop/1 ---
    refute result.alive_after_stop
    assert MapSet.size(result.armed_after_boot) == 0

    # --- after boot/4 ---
    # The machine was rebuilt from stored bytes, not carried over -
    # `%Machine{}` compares by value so `!==` against the pre-restart
    # struct would prove nothing (two compilations of the same source are
    # equal terms). Assert the path instead: `boot/4` recorded that it
    # re-fetched the chart, and the freshly compiled machine's identity
    # matches the stored run record's.
    assert {:chart_fetched, content_hash} =
             result.ledger
             |> Ledger.side_effects()
             |> Enum.find(&match?({:chart_fetched, _}, &1))

    assert content_hash == result.host_after_boot.machine.identity.content_hash
    assert %Run{content_hash: ^content_hash} = Host.run(result.host_after_boot)

    # --- after recover/1 ---
    assert is_pid(result.pid_after_recover)
    assert result.alive_after_recover
    refute result.pid_after_recover == result.pid_before
    assert [%{send_id: "sla-timer"}] = result.open_timers_after_recover

    # --- the tail: finish_invocation -> tick -> ack ---
    assert result.configs == [["cooling"], ["settling"]]
    refute Enum.any?(result.configs, &("escalated" in &1))
    assert %Run{status: :completed} = Host.run(result.host)

    # --- no duplicate side effects across the restart ---
    side_effect_keys = Ledger.side_effects(result.ledger)
    assert Enum.uniq(side_effect_keys) == side_effect_keys

    calls = result.ledger |> Ledger.calls() |> Enum.map(fn {effect, _context} -> effect end)

    invoke_calls = Enum.filter(calls, &match?({:invoke, _}, &1))
    assert [{:invoke, %Invoke{type: "myapp:enrich"}}] = invoke_calls

    sla_arm_calls =
      Enum.filter(calls, &match?({:send_delayed, %SendDelayed{send_id: "sla-timer"}}, &1))

    assert [{:send_delayed, %SendDelayed{send_id: "sla-timer"}}] = sla_arm_calls

    assert Enum.any?(calls, &match?({:cancel_invoke, %CancelInvoke{}}, &1))
    assert Enum.any?(calls, &match?({:cancel, %Cancel{send_id: "reminder-timer"}}, &1))
  end
end
