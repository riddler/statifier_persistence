defmodule StatifierPersistence.Demo.RestartDemoTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.{Cancel, CancelInvoke, DatamodelInit, Invoke, SendDelayed}
  alias Statifier.Event
  alias Statifier.Send.Routes
  alias StatifierPersistence.Demo.{Host, Ledger, Runtime, Scenario}
  alias StatifierPersistence.{Run, Runs, Storage}
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

    # The reminder-timer row (armed after the restart) is dropped once its
    # cancel is driven by the sla-timer's fire - no row of any kind is left
    # open once the run settles.
    assert Ledger.open_timers(result.ledger, result.run_id) == []

    # --- no duplicate side effects across the restart ---
    # The host's idempotency ledger, on exact contents: one row per key
    # even though `recover/1` re-ran `handler.start/2` (the re-arm and the
    # re-establishment hit existing keys and appended nothing), plus the
    # one `{:chart_fetched, _}` marker the post-restart `boot/4` wrote.
    run_id = result.host.run_id

    assert [
             {:arm_timer, {^run_id, sla_ordinal}},
             {:record_invocation, {^run_id, "enrich"}},
             {:chart_fetched, ^content_hash},
             {:arm_timer, {^run_id, reminder_ordinal}}
           ] = Ledger.side_effects(result.ledger)

    refute sla_ordinal == reminder_ordinal

    # The executor call log, on exact contents - identical to the
    # straight-through run's. The restart added no executor call at all:
    # `recover/1` re-establishes liveness host-side, through the handler,
    # never back through the seam, so neither the `:invoke` nor the
    # sla-timer's `:send_delayed` was re-emitted - st-ADR-0060's "resume
    # restores position, not liveness" stated as an assertion.
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

  # A chart identical to `Scenario.source/0` plus one extra, unreachable
  # state - the same `chart_a`/`chart_b` device
  # `StatifierPersistence.Testing.Charts` uses (charts.ex:8-15) to change
  # `Statifier.Machine.Identity.of_source/2`'s content hash without
  # changing anything about how the chart runs.
  @wrong_revision_source Scenario.source()
                         |> String.replace(
                           ~r{</scxml>\s*\z},
                           "  <state id=\"extra\"/>\n</scxml>\n"
                         )

  # sabotage: Storage.load_run_position/3 (storage.ex ~384-395) changed so
  # `precheck_identity/2`'s `{:error, {:identity_mismatch, expected,
  # actual}}` arm collapses to `{:error, :chart_not_found}` -> red (the
  # pattern match on `{:error, {:identity_mismatch, expected, actual}}`
  # below no longer matches the returned `{:error, :chart_not_found}`).
  # Reverted and confirmed green.
  test "refuses to step a stored run against a different chart revision" do
    run_id = "restart-demo-wrong-rev-#{System.unique_integer([:positive])}"
    {:ok, store} = Storage.new(InMemory, [])
    {:ok, ledger} = Ledger.start_link([])
    {:ok, runtime} = Runtime.start_link([])

    {:ok, host} =
      Host.start_run(store, ledger, runtime, run_id, Scenario.source(),
        invoke_handlers: Scenario.handlers(),
        invoke_types: Scenario.invoke_types()
      )

    host = Host.submit(host, "submit")
    assert Host.config(host) == ["enriching"]
    {:ok, position_before} = Host.position(host)

    {:ok, wrong_machine} = Statifier.compile(@wrong_revision_source)
    refute wrong_machine.identity.content_hash == host.machine.identity.content_hash

    result =
      Runs.step(store, run_id, wrong_machine, Event.external("sla.breach"),
        executor: fn _effect, _context -> :ok end,
        invoke_types: Scenario.invoke_types(),
        routes: Routes.new()
      )

    # Both identities named, per ADR-0003 decision 4 - no arm collapsed to
    # a generic reason that drops which chart was stored and which was
    # supplied.
    assert {:error, {:identity_mismatch, expected, actual}} = result
    assert expected == host.machine.identity
    assert actual == wrong_machine.identity

    {:ok, position_after} = Host.position(host)
    assert position_after == position_before
  end

  # A mutation hitting both sides identically (reordering
  # `Runs.execute_effects/3`, for one) cannot sabotage this test - the
  # restarted run and the replay would still walk identical paths. The
  # mutation below is the one that can, because it is asymmetric between
  # them: the restarted run crosses a real restart and reloads the stored
  # blob on every post-restart step, while `Scenario.replay/3` never
  # crosses a restart and never reloads anything but what it itself wrote.
  #
  # sabotage: Runs.write_run/6 (runs.ex ~512-525) changed so the `:update`
  # write path passes `position: :skip` unconditionally -> red. Both sides
  # stall (no step's result is ever stored), but asymmetrically: the
  # original's *loaded* configs stay `["intake"]` throughout, while the
  # replay's configs come off each step's *returned* state, whose first
  # element still advances to `["enriching"]` - the sequences diverge and
  # the `Enum.drop(replay_result.configs, 1) == original_configs`
  # assertion goes red (confirmed by running the mutation; the earlier
  # tests in this file go red on their own assertions too). Reverted and
  # confirmed green.
  test "replaying the recorded tape against a fresh store reproduces the same path" do
    result = Scenario.across_restart({InMemory, []})

    {:ok, replay_store} = Storage.new(InMemory, [])
    {:ok, replay_ledger} = Ledger.start_link([])
    replay_run_id = "restart-demo-replay-#{System.unique_integer([:positive])}"

    # The session id is the one non-deterministic input the original
    # create took (`MachineState.new/2` generates it; it lands in the
    # `:datamodel_init` effect's `_sessionid`/`_ioprocessors` system
    # variables). It is part of the recorded inputs, so the replay
    # re-supplies it - read here off the finished run's durable position.
    {:ok, final_position} = Host.position(result.host)
    original_session_id = final_position.datamodel["_sessionid"]

    replay_result =
      Scenario.replay(Host.tape(result.host), {replay_store, replay_ledger}, replay_run_id,
        initialize: [session_id: original_session_id]
      )

    # `result.config_at_kill` is the config after tape event 1 (`submit`);
    # `result.configs` are the configs after tape events 2 and 3
    # (`finish_invocation`, the fired `sla-timer`); `Host.config/1` on the
    # finished host is the config after tape event 4 (`ack`) - empty,
    # because reaching the top-level `<final>` exits every state. Dropping
    # `replay_result.configs`' element zero (the pre-tape config right
    # after `Runs.create/4`) lines the two sequences up one-for-one.
    original_configs = [result.config_at_kill] ++ result.configs ++ [Host.config(result.host)]
    assert Enum.drop(replay_result.configs, 1) == original_configs

    # And pinned literally, so equal-but-both-wrong sequences (a mutation
    # that stalls the restarted run and the replay identically) still go
    # red rather than sliding through the comparison above.
    assert replay_result.configs ==
             [["intake"], ["enriching"], ["cooling"], ["settling"], []]

    # Struct for struct, not tag for tag or count for count. This holds
    # because the deterministic fold state each effect carries -
    # `ordinal`, `macrostep`/`microstep`/`round`, `send_id` - comes from
    # the counters and the chart's own document-order ids, none of which
    # depend on `run_id`; the session id, the one generated input, was
    # re-supplied above. Only the executor `context` differs between the
    # two runs (it carries `run_id`, and the restarted run and the replay
    # use different ones) - which is exactly why this compares the effect
    # payloads and not the `{effect, context}` pairs the ledger actually
    # recorded.
    original_effects =
      result.ledger |> Ledger.calls() |> Enum.map(fn {effect, _context} -> effect end)

    assert replay_result.effects == original_effects
  end
end
