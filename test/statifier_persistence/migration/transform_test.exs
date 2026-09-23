defmodule StatifierPersistence.Migration.TransformTest do
  @moduledoc """
  ADR-0013 decision 6's static definition of a state that could own a
  timer, enumerated over compiled charts: one chart per place a delayed
  `<send>` can sit, and the states that schedule nothing delayed.

  The charts are library holds and loans. Each names the state expected
  to own the timer; every other state in it schedules nothing delayed.
  """

  use ExUnit.Case, async: true

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
end
