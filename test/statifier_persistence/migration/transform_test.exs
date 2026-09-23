defmodule StatifierPersistence.Migration.TransformTest do
  @moduledoc """
  ADR-0013 decision 6's static definition of a state that could own a
  timer, enumerated over compiled charts: one chart per place a delayed
  `<send>` can sit, and the states that schedule nothing delayed.

  The charts are library holds and loans. Each names the state expected
  to own the timer; every other state in it schedules nothing delayed.

  And the legality of the transformed configuration (ADR-0013's
  2026-09-23 Amendment, finding 3), one configuration per arm of the rule,
  each carried through `transform/5` by a plan that keeps every id.
  """

  use ExUnit.Case, async: true

  alias Statifier.Position
  alias StatifierPersistence.Migration.{Plan, Transform}

  defp owners(body) do
    {:ok, machine} =
      Statifier.compile("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
        <datamodel>
          <data id="pickup_window" expr="'259200s'"/>
          <data id="copies" expr="[1, 2]"/>
        </datamodel>
        #{body}
        <final id="closed"/>
      </scxml>
      """)

    Transform.timer_owners(machine)
  end

  # sabotage: dropped the onentry and onexit blocks from
  # owns_delayed_send?/2 -> red: the answer was []. Verified red, reverted
  # from a copy.
  test "a delayed send in onentry makes its state an owner" do
    assert owners("""
           <state id="hold">
             <onentry><send id="pickup" event="pickup.expired" delay="259200s"/></onentry>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: made owns_delayed_send?/2 read onentry blocks only (onexit
  # left out) -> red: the answer was []. Verified red, reverted from a copy.
  test "a delayed send in onexit makes its state an owner" do
    assert owners("""
           <state id="hold">
             <onexit><send id="reminder" event="loan.reminder" delay="604800s"/></onexit>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: made delayed_send_in?/2 answer false for a Send whose delay
  # is compiled (the delayexpr arm) -> red: the answer was []. Verified red,
  # reverted from a copy.
  test "a delayexpr counts as a delay" do
    assert owners("""
           <state id="hold">
             <onentry><send id="pickup" event="pickup.expired" delayexpr="pickup_window"/></onentry>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: dropped `state.transitions` from owns_delayed_send?/2's list
  # -> red: the answer was []. Verified red, reverted from a copy.
  test "a delayed send in a transition makes the transition's source an owner" do
    assert owners("""
           <state id="hold" initial="placed">
             <state id="placed">
               <transition event="copy.available" target="routing">
                 <send id="pickup" event="pickup.expired" delay="259200s"/>
               </transition>
             </state>
             <state id="routing">
               <transition event="copy.collected" target="closed"/>
             </state>
           </state>
           """) == ["placed"]
  end

  # sabotage: dropped `state.initial_transition` from owns_delayed_send?/2's
  # list -> red: the answer was []. Verified red, reverted from a copy.
  test "a delayed send in an <initial> element's transition makes its parent an owner" do
    assert owners("""
           <state id="hold">
             <initial>
               <transition target="placed">
                 <send id="pickup" event="pickup.expired" delay="259200s"/>
               </transition>
             </initial>
             <state id="placed">
               <transition event="copy.collected" target="closed"/>
             </state>
           </state>
           """) == ["hold"]
  end

  # sabotage: dropped `state.history_default` from owns_delayed_send?/2's
  # list -> red: the answer was []. Verified red, reverted from a copy.
  test "a delayed send in a history default makes the history state an owner" do
    assert owners("""
           <state id="hold" initial="placed">
             <history id="hold_history" type="shallow">
               <transition target="placed">
                 <send id="pickup" event="pickup.expired" delay="259200s"/>
               </transition>
             </history>
             <state id="placed">
               <transition event="copy.collected" target="closed"/>
             </state>
           </state>
           """) == ["hold_history"]
  end

  # sabotage: dropped the finalize blocks from owns_delayed_send?/2 -> red:
  # the answer was []. Verified red, reverted from a copy.
  test "a delayed send in an <invoke>'s <finalize> makes the invoking state an owner" do
    assert owners("""
           <state id="hold">
             <invoke id="notice" type="library:notify_patron">
               <finalize><send id="pickup" event="pickup.expired" delay="259200s"/></finalize>
             </invoke>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: made delayed_send_in?/2's If clause answer false -> red: the
  # answer was []. Verified red, reverted from a copy.
  test "a delayed send nested in an <if> branch counts" do
    assert owners("""
           <state id="hold">
             <onentry>
               <if cond="pickup_window == 'none'">
                 <log expr="'no deadline'"/>
               <else/>
                 <send id="pickup" event="pickup.expired" delay="259200s"/>
               </if>
             </onentry>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: made delayed_send_in?/2's Foreach clause answer false -> red:
  # the answer was []. Verified red, reverted from a copy.
  test "a delayed send nested in a <foreach> body counts" do
    assert owners("""
           <state id="hold">
             <onentry>
               <foreach array="copies" item="copy">
                 <send event="copy.recall" delay="86400s"/>
               </foreach>
             </onentry>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == ["hold"]
  end

  # sabotage: made delayed_send_in?/2 answer true for every Send, delayed or
  # not -> red: the answer was ["hold"]. Verified red, reverted from a copy.
  test "an undelayed send, and a state with no content, own nothing" do
    assert owners("""
           <state id="hold">
             <onentry><send event="hold.placed"/></onentry>
             <transition event="copy.collected" target="closed"/>
           </state>
           """) == []
  end

  # sabotage: made timer_owners/1 map every state to its id, dropping the
  # index fallback -> red: the answer held nil. Verified red, reverted from
  # a copy.
  test "a state with no id is named by its index" do
    {:ok, machine} =
      Statifier.compile("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
        <state id="hold">
          <state>
            <onentry><send id="pickup" event="pickup.expired" delay="259200s"/></onentry>
          </state>
        </state>
      </scxml>
      """)

    assert [index] = Transform.timer_owners(machine)
    assert is_integer(index)
    assert Statifier.Machine.at(machine, index).id == nil
  end

  describe "timer_states/3" do
    @from """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
      <state id="hold" initial="placed">
        <state id="placed">
          <onentry><send id="expiry" event="hold.expired" delay="2592000s"/></onentry>
          <transition event="copy.available" target="awaiting_pickup"/>
        </state>
        <state id="awaiting_pickup">
          <onentry><send id="pickup" event="pickup.expired" delay="259200s"/></onentry>
          <transition event="copy.collected" target="fulfilled"/>
        </state>
        <state id="in_transit">
          <onentry><send id="transit" event="transit.late" delay="86400s"/></onentry>
          <transition event="copy.routed" target="awaiting_pickup"/>
        </state>
      </state>
      <final id="fulfilled"/>
    </scxml>
    """

    @to """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
      <state id="hold" initial="placed">
        <state id="placed">
          <transition event="copy.available" target="ready_for_pickup"/>
        </state>
        <state id="ready_for_pickup">
          <transition event="copy.collected" target="fulfilled"/>
        </state>
      </state>
      <final id="fulfilled"/>
    </scxml>
    """

    # sabotage: made timer_states/3 put a dropped owner under :unmapped ->
    # red: in_transit showed up unmapped and dropped was []. Verified red,
    # reverted from a copy.
    test "splits the owners a plan leaves unmapped from those it drops, mapped ones in neither" do
      {:ok, from} = Statifier.compile(@from)
      {:ok, to} = Statifier.compile(@to)

      # `placed` keeps its id and `awaiting_pickup` is renamed, so both are
      # mapped; `in_transit` is dropped.
      {:ok, plan} =
        Plan.new(
          from: from.identity.content_hash,
          to: to.identity.content_hash,
          states: %{"awaiting_pickup" => "ready_for_pickup"},
          drop: ["in_transit"]
        )

      assert Transform.timer_states(plan, from, to) == %{unmapped: [], dropped: ["in_transit"]}

      {:ok, plan} =
        Plan.new(from: from.identity.content_hash, to: to.identity.content_hash)

      assert Transform.timer_states(plan, from, to) ==
               %{unmapped: ["awaiting_pickup", "in_transit"], dropped: []}
    end
  end

  describe "the transformed configuration's legality" do
    # A branch's desk: a hold (with a history state), a loan, and a pickup
    # that runs the patron notice and the desk slip as two regions.
    @desk """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
      <state id="hold" initial="placed">
        <history id="hold_history" type="shallow">
          <transition target="placed"/>
        </history>
        <state id="placed">
          <transition event="copy.available" target="routing"/>
        </state>
        <state id="routing">
          <transition event="copy.routed" target="pickup"/>
        </state>
      </state>
      <state id="loan" initial="on_loan">
        <state id="on_loan">
          <transition event="copy.returned" target="returned"/>
        </state>
      </state>
      <parallel id="pickup">
        <state id="notice_region" initial="notice_pending">
          <state id="notice_pending"/>
        </state>
        <state id="slip_region" initial="slip_pending">
          <state id="slip_pending"/>
        </state>
        <transition event="copy.collected" target="loan"/>
      </parallel>
      <final id="returned"/>
    </scxml>
    """

    # The desk's position with `configuration` in place of its own - an
    # import checks ids, not legality - carried through a plan that keeps
    # every id, onto the same chart.
    defp transform_at(configuration) do
      {:ok, machine} = Statifier.compile(@desk)
      {initial, _effects} = Statifier.Interpreter.initialize(machine)
      {:ok, exported} = Position.export(initial)

      {:ok, machine_state} =
        Position.import(machine, %{exported | configuration: MapSet.new(configuration)})

      hash = machine.identity.content_hash
      {:ok, plan} = Plan.new(from: hash, to: hash)
      Transform.transform(machine_state, plan, machine, machine, %{})
    end

    # sabotage: made configuration_findings/2 (migration/transform.ex)
    # answer a finding for every configuration -> red: both legal
    # configurations were refused. Verified red, reverted from a copy.
    test "a legal configuration, compound or parallel, transforms" do
      assert {:ok, _applied} = transform_at(~w(hold placed))

      assert {:ok, _applied} =
               transform_at(~w(pickup notice_region notice_pending slip_region slip_pending))
    end

    # sabotage: made legal_at?/3's compound arm (migration/transform.ex)
    # accept any count below two -> red: the hold with no active child
    # transformed. Verified red, reverted from a copy.
    test "a compound state with no child state in the configuration is refused" do
      assert transform_at(~w(hold)) == {:error, [{:illegal_configuration, ["hold"]}]}
    end

    # sabotage: made legal_at?/3's compound arm (migration/transform.ex)
    # accept any count above zero -> red: both configurations transformed.
    # Verified red, reverted from a copy.
    test "a compound state, the root included, with two child states in it is refused" do
      assert transform_at(~w(hold placed routing)) ==
               {:error, [{:illegal_configuration, ["hold", "placed", "routing"]}]}

      assert transform_at(~w(hold placed loan on_loan)) ==
               {:error, [{:illegal_configuration, ["hold", "loan", "on_loan", "placed"]}]}
    end

    # sabotage: made legal_at?/3's parallel arm (migration/transform.ex)
    # answer true -> red: the pickup without its slip region transformed.
    # Verified red, reverted from a copy.
    test "a parallel state missing one of its child states is refused" do
      assert transform_at(~w(pickup notice_region notice_pending)) ==
               {:error, [{:illegal_configuration, ["notice_pending", "notice_region", "pickup"]}]}
    end

    # sabotage: made legal_at?/3's atomic arm (migration/transform.ex)
    # answer true -> red: on_loan transformed without its parent. Verified
    # red, reverted from a copy.
    test "an atomic state missing a proper ancestor is refused" do
      assert transform_at(~w(hold placed on_loan)) ==
               {:error, [{:illegal_configuration, ["hold", "on_loan", "placed"]}]}
    end

    # sabotage: made legal_at?/3's history arm (migration/transform.ex)
    # answer true -> red: the history state transformed as a member of the
    # configuration. Verified red, reverted from a copy.
    test "a history pseudo-state in the configuration is refused" do
      assert transform_at(~w(hold placed hold_history)) ==
               {:error, [{:illegal_configuration, ["hold", "hold_history", "placed"]}]}
    end
  end
end
