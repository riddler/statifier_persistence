defmodule StatifierPersistence.Migration.PlanTest do
  use ExUnit.Case, async: true

  alias StatifierPersistence.Migration.Plan

  # A library hold before the edit: the copy is routed to the patron's branch
  # and the hold waits in `awaiting_pickup`, whose entry schedules the pickup
  # deadline and notifies the patron.
  @hold_before """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <history id="hold_history" type="shallow">
        <transition target="placed"/>
      </history>
      <state id="placed">
        <transition event="copy.available" target="routing"/>
      </state>
      <state id="routing">
        <transition event="copy.routed" target="awaiting_pickup"/>
      </state>
      <state id="awaiting_pickup">
        <onentry>
          <send id="pickup" event="pickup.expired" delay="259200s"/>
        </onentry>
        <invoke id="notice" type="library:notify_patron"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
      <transition event="hold.suspended" target="suspended"/>
    </state>
    <state id="suspended">
      <transition event="hold.resumed" target="hold_history"/>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  # The same hold after the edit: `awaiting_pickup` is renamed
  # `ready_for_pickup`, and routing gains a `transferred` outcome leading to
  # a new state.
  @hold_after """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="hold">
    <state id="hold" initial="placed">
      <history id="hold_history" type="shallow">
        <transition target="placed"/>
      </history>
      <state id="placed">
        <transition event="copy.available" target="routing"/>
      </state>
      <state id="routing">
        <transition event="copy.routed" target="ready_for_pickup"/>
        <transition event="copy.transferred" target="transferred"/>
      </state>
      <state id="transferred">
        <transition event="copy.routed" target="ready_for_pickup"/>
      </state>
      <state id="ready_for_pickup">
        <onentry>
          <send id="pickup" event="pickup.expired" delay="259200s"/>
        </onentry>
        <invoke id="notice" type="library:notify_patron"/>
        <transition event="copy.collected" target="fulfilled"/>
        <transition event="pickup.expired" target="expired"/>
      </state>
      <transition event="hold.suspended" target="suspended"/>
    </state>
    <state id="suspended">
      <transition event="hold.resumed" target="hold_history"/>
    </state>
    <final id="fulfilled"/>
    <final id="expired"/>
  </scxml>
  """

  setup_all do
    {:ok, from_machine} = Statifier.compile(@hold_before)
    {:ok, to_machine} = Statifier.compile(@hold_after)

    %{
      from_machine: from_machine,
      to_machine: to_machine,
      from_hash: from_machine.identity.content_hash,
      to_hash: to_machine.identity.content_hash
    }
  end

  defp plan!(ctx, fields) do
    {:ok, plan} = Plan.new([from: ctx.from_hash, to: ctx.to_hash] ++ fields)
    plan
  end

  defp rename_plan!(ctx, fields \\ []) do
    plan!(ctx, [states: %{"awaiting_pickup" => "ready_for_pickup"}] ++ fields)
  end

  describe "validate/3 against the library hold's edit" do
    # sabotage: made mapping_findings/4 look the target id up in the from
    # machine instead of the to machine -> red (ready_for_pickup came back as
    # an unknown target)
    test "the rename plan validates", ctx do
      plan =
        rename_plan!(ctx,
          invocations: [{"awaiting_pickup", 0, "ready_for_pickup", 0}],
          datamodel: [{:add, "transfer_branch", nil}]
        )

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) == :ok
    end

    # sabotage: made unknown/4 answer [] for every id -> red (the misspelt
    # source was accepted)
    test "a source id missing from the from chart is refused, naming it", ctx do
      plan = plan!(ctx, states: %{"awaiting_collection" => "ready_for_pickup"})

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:unknown_source, :states, "awaiting_collection"}]}
    end

    # sabotage: made mapping_findings/4 skip the target lookup -> red (the
    # target the to chart does not have was accepted)
    test "a target id missing from the to chart is refused, naming it", ctx do
      plan = plan!(ctx, states: %{"awaiting_pickup" => "ready_for_collection"})

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:unknown_target, :states, "ready_for_collection"}]}
    end

    # sabotage: dropped plan.drop from the list duplicate_source_findings/1
    # counts -> red (the state both renamed and dropped was accepted)
    test "a source id used twice is refused, naming it", ctx do
      plan = rename_plan!(ctx, drop: ["awaiting_pickup"])

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:duplicate_source, "awaiting_pickup"}]}
    end

    # sabotage: made the :history clause of history_findings/5 answer [] ->
    # red (the history state mapped onto a plain state was accepted)
    test "a history state mapped to a plain state is refused, naming both", ctx do
      plan = plan!(ctx, history: %{"hold_history" => "placed"})

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:history_mismatch, :history, "hold_history", "placed"}]}
    end

    # sabotage: made the :states clause of history_findings/5 answer [] ->
    # red (the history state renamed onto a plain state through :states was
    # accepted)
    test "a history state mapped to a plain state through :states is refused", ctx do
      plan = plan!(ctx, states: %{"hold_history" => "placed"})

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:history_mismatch, :states, "hold_history", "placed"}]}
    end

    # sabotage: changed `ordinal < invoke_count` to `ordinal <= invoke_count`
    # in ordinal_findings/4 -> red (ordinal 1 of a state with one invoke was
    # accepted)
    test "an out-of-range invocation ordinal is refused on either side", ctx do
      plan =
        rename_plan!(ctx,
          invocations: [
            {"awaiting_pickup", 1, "ready_for_pickup", 0},
            {"placed", 0, "ready_for_pickup", 3}
          ]
        )

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error,
                [
                  {:invocation_out_of_range, :from, "awaiting_pickup", 1, 1},
                  {:invocation_out_of_range, :from, "placed", 0, 0},
                  {:invocation_out_of_range, :to, "ready_for_pickup", 3, 1}
                ]}
    end

    # sabotage: made validate/3 answer only the first finding -> red (four of
    # the five faults went unreported)
    test "every fault is answered in one call, never only the first", ctx do
      plan =
        plan!(ctx,
          states: %{
            "awaiting_collection" => "ready_for_pickup",
            "awaiting_pickup" => "ready_for_collection"
          },
          drop: ["awaiting_pickup"],
          history: %{"hold_history" => "placed"},
          invocations: [{"awaiting_pickup", 1, "ready_for_pickup", 0}]
        )

      assert {:error, findings} = Plan.validate(plan, ctx.from_machine, ctx.to_machine)

      assert Enum.sort(findings) ==
               Enum.sort([
                 {:unknown_source, :states, "awaiting_collection"},
                 {:unknown_target, :states, "ready_for_collection"},
                 {:duplicate_source, "awaiting_pickup"},
                 {:history_mismatch, :history, "hold_history", "placed"},
                 {:invocation_out_of_range, :from, "awaiting_pickup", 1, 1}
               ])
    end

    # sabotage: made identity_findings/3 answer [] for a machine whose hash
    # differs -> red (the swapped hashes were accepted)
    test "machines that do not carry the plan's hashes are refused", ctx do
      {:ok, plan} = Plan.new(from: ctx.to_hash, to: ctx.from_hash)

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error,
                [
                  {:identity_mismatch, :from, ctx.to_hash, ctx.from_hash},
                  {:identity_mismatch, :to, ctx.from_hash, ctx.to_hash}
                ]}
    end

    # sabotage: made identity_findings/3's nil clause answer [] -> red (a
    # machine compiled without an identity was accepted)
    test "a machine with no identity is refused", ctx do
      plan = rename_plan!(ctx)

      assert Plan.validate(plan, ctx.from_machine, %{ctx.to_machine | identity: nil}) ==
               {:error, [{:identity_mismatch, :to, ctx.to_hash, nil}]}
    end

    # sabotage: removed the :to call to duplicate_invocations/2 -> red (two
    # invocations moved onto one target were accepted)
    test "two invocations that share a target are refused", ctx do
      plan =
        rename_plan!(ctx,
          invocations: [
            {"awaiting_pickup", 0, "ready_for_pickup", 0},
            {"awaiting_pickup", 0, "ready_for_pickup", 0}
          ]
        )

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error,
                [
                  {:duplicate_invocation, :from, {"awaiting_pickup", 0}},
                  {:duplicate_invocation, :to, {"ready_for_pickup", 0}}
                ]}
    end

    # sabotage: made drop_findings/2 answer [] -> red (a dropped id the from
    # chart does not have was accepted)
    test "a dropped id missing from the from chart is refused", ctx do
      plan = rename_plan!(ctx, drop: ["awaiting_collection"])

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error, [{:unknown_source, :drop, "awaiting_collection"}]}
    end

    # sabotage: made ordinal_findings/4 answer [] for an unknown state -> red
    # (the invocation naming a state neither chart has was accepted)
    test "an invocation naming an unknown state is refused on either side", ctx do
      plan = rename_plan!(ctx, invocations: [{"awaiting_collection", 0, "shelved", 0}])

      assert Plan.validate(plan, ctx.from_machine, ctx.to_machine) ==
               {:error,
                [
                  {:unknown_source, :invocations, "awaiting_collection"},
                  {:unknown_target, :invocations, "shelved"}
                ]}
    end
  end

  describe "the map form" do
    # sabotage: made to_map/1 write invocations as tuples -> red (the JSON
    # encoder refused the tuple)
    test "every field round-trips through the map form and through JSON", ctx do
      plan =
        plan!(ctx,
          states: %{"awaiting_pickup" => "ready_for_pickup"},
          drop: ["suspended"],
          history: %{"hold_history" => "hold_history"},
          invocations: [{"awaiting_pickup", 0, "ready_for_pickup", 0}],
          datamodel: [
            {:add, "transfer_branch", %{"name" => "Riverside", "shelves" => [1, 2.5, true]}},
            {:rename, "pickup_branch", "collection_branch"},
            {:remove, "hold_note"}
          ]
        )

      assert Plan.from_map(Plan.to_map(plan)) == {:ok, plan}

      assert plan |> Plan.to_map() |> JSON.encode!() |> JSON.decode!() |> Plan.from_map() ==
               {:ok, plan}
    end

    # sabotage: made to_map/1 write "timers" as %{keep_mapped: true} -> red
    # (an atom key reached the map form)
    test "the map form has string keys only and matches the record's shape", ctx do
      plan = rename_plan!(ctx, datamodel: [{:add, "transfer_branch", nil}])

      assert Plan.to_map(plan) == %{
               "from" => ctx.from_hash,
               "to" => ctx.to_hash,
               "states" => %{"awaiting_pickup" => "ready_for_pickup"},
               "drop" => [],
               "history" => %{},
               "invocations" => [],
               "timers" => %{"keep_mapped" => true},
               "datamodel" => [%{"op" => "add", "key" => "transfer_branch", "value" => nil}]
             }
    end

    # sabotage: made from_map/1 skip known_keys/2 -> red (the atom key was
    # read as a field instead of refused)
    test "an atom key or an unknown key is refused", ctx do
      assert Plan.from_map(%{from: ctx.from_hash, to: ctx.to_hash}) ==
               {:error, {:malformed_plan, :plan, {:unknown_keys, [:from, :to]}}}

      assert Plan.from_map(%{"from" => ctx.from_hash, "to" => ctx.to_hash, "note" => "x"}) ==
               {:error, {:malformed_plan, :plan, {:unknown_keys, ["note"]}}}
    end

    # sabotage: made decode_op/1 read any map with "from" and "to" as a
    # rename -> red (the operation with an unknown op was accepted)
    test "a datamodel operation of another shape is refused, naming its index", ctx do
      op = %{"op" => "copy", "from" => "pickup_branch", "to" => "collection_branch"}

      assert Plan.from_map(%{"from" => ctx.from_hash, "to" => ctx.to_hash, "datamodel" => [op]}) ==
               {:error, {:malformed_plan, :datamodel, {:invalid_operation, 0, op}}}
    end

    # sabotage: made decode_invocation/1 read a three-element list as an
    # invocation with ordinal 0 -> red (the short entry was accepted)
    test "an invocation that is not a four-element list is refused", ctx do
      entry = ["awaiting_pickup", 0, "ready_for_pickup"]

      assert Plan.from_map(%{
               "from" => ctx.from_hash,
               "to" => ctx.to_hash,
               "invocations" => [entry]
             }) == {:error, {:malformed_plan, :invocations, {:invalid_entry, entry}}}
    end

    # sabotage: made from_map/1 hand a non-map to new/1 -> red (the empty
    # list came back as a missing :from instead)
    test "a value that is not a map is refused" do
      assert Plan.from_map([]) == {:error, {:malformed_plan, :plan, :not_a_map}}
    end
  end

  describe "new/1" do
    # sabotage: made hash/2 default a missing :from to "" -> red (the missing
    # field was reported as invalid instead of missing)
    test "a plan without a from hash is refused, naming the field", ctx do
      assert Plan.new(to: ctx.to_hash) == {:error, {:malformed_plan, :from, :missing}}

      assert Plan.new(from: "", to: ctx.to_hash) ==
               {:error, {:malformed_plan, :from, {:invalid, ""}}}
    end

    # sabotage: made timers/1 accept any map -> red (keep_mapped: false was
    # accepted)
    test "timers admit only keep_mapped: true", ctx do
      assert Plan.new(from: ctx.from_hash, to: ctx.to_hash, timers: %{keep_mapped: false}) ==
               {:error, {:malformed_plan, :timers, {:invalid, %{keep_mapped: false}}}}
    end

    # sabotage: made the "_" clause of key_fault/2 unreachable -> red (the system
    # variable was accepted as a key)
    test "a datamodel key naming a system variable is refused", ctx do
      assert Plan.new(
               from: ctx.from_hash,
               to: ctx.to_hash,
               datamodel: [{:remove, "hold_note"}, {:rename, "pickup_branch", "_event"}]
             ) == {:error, {:malformed_plan, :datamodel, {:system_variable, 1, "_event"}}}
    end

    # sabotage: made literal?/1 answer true for every value -> red (the atom
    # value was accepted and would not survive the codec)
    test "a datamodel value that is not a JSON literal is refused", ctx do
      assert Plan.new(
               from: ctx.from_hash,
               to: ctx.to_hash,
               datamodel: [{:add, "transfer_branch", %{"branch" => :riverside}}]
             ) ==
               {:error,
                {:malformed_plan, :datamodel, {:not_a_literal, 0, %{"branch" => :riverside}}}}
    end

    # sabotage: made id_map/2 accept any map -> red (the integer target was
    # accepted)
    test "a state mapping to a non-id is refused, naming the entry", ctx do
      assert Plan.new(from: ctx.from_hash, to: ctx.to_hash, states: %{"awaiting_pickup" => 7}) ==
               {:error, {:malformed_plan, :states, {:invalid_entry, {"awaiting_pickup", 7}}}}
    end

    # sabotage: made id_list/2 accept any list -> red (the empty id was
    # accepted)
    test "a drop that is not a list of ids is refused", ctx do
      assert Plan.new(from: ctx.from_hash, to: ctx.to_hash, drop: [""]) ==
               {:error, {:malformed_plan, :drop, {:invalid_entry, ""}}}

      assert Plan.new(from: ctx.from_hash, to: ctx.to_hash, drop: "suspended") ==
               {:error, {:malformed_plan, :drop, {:not_a_list, "suspended"}}}
    end

    # sabotage: made invocation?/1 accept a negative ordinal -> red (ordinal
    # -1 was accepted)
    test "an invocation with a negative ordinal is refused", ctx do
      entry = {"awaiting_pickup", -1, "ready_for_pickup", 0}

      assert Plan.new(from: ctx.from_hash, to: ctx.to_hash, invocations: [entry]) ==
               {:error, {:malformed_plan, :invocations, {:invalid_entry, entry}}}
    end

    # sabotage: made new/1 accept a non-keyword list by treating it as empty
    # -> red (the bare list was answered as a missing :from instead)
    test "neither a keyword list nor a map is refused" do
      assert Plan.new(["awaiting_pickup"]) ==
               {:error, {:malformed_plan, :plan, :not_a_keyword_list_or_map}}

      assert Plan.new("plan") == {:error, {:malformed_plan, :plan, :not_a_keyword_list_or_map}}
    end
  end
end
