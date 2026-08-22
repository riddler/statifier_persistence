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
end
