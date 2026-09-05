defmodule StatifierPersistence.DriverFanoutTest do
  @moduledoc """
  Tier A fan-out (sp-t57): `StatifierPersistence.Driver.start_child_at/6`
  starts child `i` of `N` with the count and the aggregation policy on its
  linkage, and refuses at open on a store that could not settle the
  invocation afterwards.
  """

  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Runs, Storage}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory

  alias StatifierPersistence.Test.{
    NoChildListingAdapter,
    NoRunOutcomeAdapter,
    NoRunStatesAdapter,
    RaisingListingAdapter
  }

  # The parent: one `<invoke>` the scheduler fans out. It rests in
  # "calling" with the invocation live, exactly as a single-child subchart
  # parent does, because this package never starts the children itself -
  # the scheduler calls `start_child_at/6` from its own jobs.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  # A child that completes on "go" with the item it was seeded with as
  # its donedata: the fan-out's assembled list has to be a function of the
  # index, so each child has to answer something different.
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <datamodel><data id="item"/></datamodel>
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done">
          <donedata><content expr="item"/></donedata>
      </final>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
  end

  describe "start_child_at/6" do
    # sabotage: in Driver.child_linkage/3's tuple clause, pass 0 instead of
    # the given index to Linkage.new/6 -> red, both children landed on the
    # index-0 run id and the second create adopted the first, so the
    # index-1 fetch below returned :run_not_found. Verified red, reverted.
    test "creates child i of N with the count and policy on its linkage", %{store: store} do
      driver = start_parent(store)

      assert :ok = Driver.start_child_at(driver, "run_1", effect(), 0, 3)
      assert :ok = Driver.start_child_at(driver, "run_1", effect(), 2, 3, policy: :first_error)

      assert {:ok, first} = Storage.fetch_run(store, Linkage.child_run_id("run_1", "call", 0))
      assert {:ok, third} = Storage.fetch_run(store, Linkage.child_run_id("run_1", "call", 2))

      assert first.status == :active
      assert {:ok, first_linkage} = Linkage.from_metadata(first.metadata)
      assert first_linkage.child_index == 0
      assert first_linkage.child_count == 3
      assert first_linkage.policy == :all
      assert Linkage.fan_out?(first_linkage)

      assert {:ok, third_linkage} = Linkage.from_metadata(third.metadata)
      assert third_linkage.child_index == 2
      assert third_linkage.policy == :first_error

      {:ok, child_machine} = Statifier.compile(@child_source)
      assert first_linkage.content_hash == Machine.identity(child_machine).content_hash
    end

    # sabotage: in Driver.create_child/6, treat {:error, :run_exists} as an
    # ordinary refusal (drop the adopt_child/3 clause) -> red, the second
    # call answered {:refused, :run_exists} instead of :ok. Verified red,
    # reverted.
    test "a re-delivered start job for the same index adopts rather than duplicating", %{
      store: store
    } do
      driver = start_parent(store)

      assert :ok = Driver.start_child_at(driver, "run_1", effect(), 1, 3)
      child_run_id = Linkage.child_run_id("run_1", "call", 1)
      assert {:ok, first} = Storage.fetch_run(store, child_run_id)

      assert :ok = Driver.start_child_at(driver, "run_1", effect(), 1, 3)

      assert {:ok, second} = Storage.fetch_run(store, child_run_id)
      assert second == first
    end

    # The bound is Linkage.new/6's, and this asserts start_child_at/6
    # reaches it rather than swallowing it.
    #
    # sabotage: in Linkage.new/6, compare child_index against
    # child_count + 1 -> red, index 3 of 3 was accepted here and in
    # run_linkage_test's own bound case. Verified red, reverted.
    test "an index outside 0..count - 1 raises" do
      {:ok, store} = Storage.new(InMemory, [])
      driver = start_parent(store)

      assert_raise ArgumentError, fn ->
        Driver.start_child_at(driver, "run_1", effect(), 3, 3)
      end
    end

    # sabotage: in Driver.start_context/3, ignore the fetch_run/2 refusal
    # and build the context anyway -> red, the call answered :ok and
    # created a child linked to a parent that does not exist. Verified
    # red, reverted.
    test "a parent id naming no stored run refuses :run_not_found", %{store: store} do
      driver = start_parent(store)

      assert {:refused, :run_not_found} =
               Driver.start_child_at(driver, "run_missing", effect(), 0, 1)
    end

    # sabotage: in Driver.settleable/4, collapse the three cond arms to the
    # child-listing one -> red, the outcome and projection adapters both
    # started a child instead of refusing. Verified red, reverted.
    test "refuses at open on a store that could not settle the invocation" do
      for {adapter, reason} <- [
            {NoChildListingAdapter, :child_listing_unsupported},
            {NoRunOutcomeAdapter, :run_outcome_unsupported},
            {NoRunStatesAdapter, :run_states_unsupported}
          ] do
        {:ok, store} = Storage.new(adapter, [])
        driver = start_parent(store)

        assert {:refused, ^reason} = Driver.start_child_at(driver, "run_1", effect(), 0, 2),
               "expected #{inspect(adapter)} to refuse with #{inspect(reason)}"

        assert {:error, :run_not_found} =
                 Storage.fetch_run(store, Linkage.child_run_id("run_1", "call", 0))
      end
    end

    # sabotage: in Driver.child_linkage/3, make the nil clause build a
    # fan-out linkage of one (Linkage.new/6 with 1 and :all) -> red, the
    # single-child path's stored metadata grew the two keys and this
    # assertion saw child_count 1 instead of nil. Verified red, reverted.
    test "the single-child subchart path records neither value", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch())

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_single")

      assert {:ok, record} =
               Storage.fetch_run(store, Linkage.child_run_id("run_single", "call", 0))

      assert {:ok, linkage} = Linkage.from_metadata(record.metadata)
      refute Linkage.fan_out?(linkage)
      assert linkage.child_count == nil
      assert linkage.policy == nil
    end

    # sabotage: in Driver.resolved_invoke/1, drop the tuple clause -> red,
    # the instruction form raised FunctionClauseError instead of starting
    # the child. Verified red, reverted.
    test "takes the whole start_child instruction as well as a bare invoke", %{store: store} do
      driver = start_parent(store)
      invoke = effect()

      assert :ok =
               Driver.start_child_at(
                 driver,
                 "run_1",
                 {:start_child, invoke, {:invoke, invoke}},
                 0,
                 1
               )

      assert {:ok, _record} = Storage.fetch_run(store, Linkage.child_run_id("run_1", "call", 0))
    end
  end

  describe "settlement" do
    # sabotage: in Driver.answer_parent/3, drop the `child_count: nil`
    # clause so every linkage answers the door directly -> red, the first
    # child to finish completed the whole invocation with its own
    # donedata. Also verified with two narrower mutations: making
    # entry/5 pass nil instead of the decoded outcome_blob (red, every
    # donedata came back nil) and dropping assemble/4's Enum.reverse
    # (red, the list came back index-descending). All three verified red,
    # reverted.
    test "N=3 settle to one assembled answer in index order through the parent's door", %{
      store: store
    } do
      parent = start_parent(store)
      start_children(parent, 3)

      # Finished out of order on purpose: the list is a function of the
      # index, not of the order the children happened to finish in.
      for index <- [2, 0, 1], do: finish_child(store, index)

      assert leaves(reload_parent(store)) == ["approved"]

      assert answered(store) == [
               %{"index" => 0, "status" => "completed", "donedata" => "item-0"},
               %{"index" => 1, "status" => "completed", "donedata" => "item-1"},
               %{"index" => 2, "status" => "completed", "donedata" => "item-2"}
             ]
    end

    # sabotage: in Driver.answer_parent/3, drop the `child_count: nil`
    # clause -> red, the parent left "calling" as soon as the first child
    # finished. Verified red, reverted. (The settled?/3 count itself is
    # sabotaged by the `:all` test below, which is the case that
    # distinguishes its two readings.)
    test "the parent does not move until the last child settles", %{store: store} do
      parent = start_parent(store)
      start_children(parent, 3)

      finish_child(store, 0)
      assert leaves(reload_parent(store)) == ["calling"]

      finish_child(store, 1)
      assert leaves(reload_parent(store)) == ["calling"]

      finish_child(store, 2)
      assert leaves(reload_parent(store)) == ["approved"]
    end

    # The arm the count is actually for. A projection over a fan-out whose
    # scheduler has not started every child yet returns fewer rows than
    # N, and every one of them can be terminal while answers are still
    # coming - so "all the rows I can see are terminal" is the wrong test
    # under `:all`, and only comparing against child_count is right.
    #
    # sabotage: in Driver.settled?/3, compare the terminal count against
    # length(states) rather than child_count on the not-cancelled arm ->
    # red, the parent answered a two-entry list plus a nil-donedata third
    # while index 2's start job was still queued. Verified red, reverted.
    test "under :all an index whose start job has not run yet is not settled", %{store: store} do
      parent = start_parent(store)

      # Index 2 is still in the scheduler's queue and has no run at all.
      assert :ok = Driver.start_child_at(parent, "run_1", effect("item-0"), 0, 3)
      assert :ok = Driver.start_child_at(parent, "run_1", effect("item-1"), 1, 3)

      finish_child(store, 0)
      finish_child(store, 1)

      assert leaves(reload_parent(store)) == ["calling"]

      # It settles when the late child finally starts and finishes.
      assert :ok = Driver.start_child_at(parent, "run_1", effect("item-2"), 2, 3)
      finish_child(store, 2)

      assert leaves(reload_parent(store)) == ["approved"]
      assert length(answered(store)) == 3
    end

    # sabotage: in Driver.settle_child/4, drop record_outcome/3 from the
    # with-chain -> red, every assembled entry came back with a nil
    # donedata because no child's answer was ever stored. Verified red,
    # reverted.
    test "N=1 settles through the same path and answers a one-entry list", %{store: store} do
      parent = start_parent(store)
      start_children(parent, 1)

      finish_child(store, 0)

      assert leaves(reload_parent(store)) == ["approved"]

      assert answered(store) == [
               %{"index" => 0, "status" => "completed", "donedata" => "item-0"}
             ]
    end

    # Scoped to the settlement's own question. The listing is legitimately
    # used elsewhere on this path - the parent's exit from the invoking
    # state cascades a cancel over the invocation, which walks records
    # (ADR-0008 decision 5) - so this drives the two settlements that
    # answer nothing and stops before the one that answers.
    #
    # sabotage: in Driver.settle/3, ask Storage.list_runs_by_metadata/2
    # instead of the projection -> red, the adapter raised on the first
    # child's settlement. Verified red, reverted.
    test "the settlement test asks the projection and never the listing" do
      {:ok, store} = Storage.new(RaisingListingAdapter, [])
      parent = start_parent(store)
      start_children(parent, 3)

      finish_child(store, 0)
      finish_child(store, 1)

      assert leaves(reload_parent(store)) == ["calling"]
    end

    # sabotage: in Driver.maybe_cancel/4, answer {:ok, states, false} from
    # the :first_error clause without running the cascade -> red, the live
    # child 2 was never cancelled, the settlement said not yet, and the
    # parent stayed in "calling". Also verified by making cancelled_entry/1
    # report "completed" (red here on the third entry). Both verified red,
    # reverted.
    test "first_error cancels a live sibling and the answer reads it cancelled", %{store: store} do
      parent = start_parent(store)
      start_children(parent, 3, policy: :first_error)

      finish_child(store, 0)
      assert leaves(reload_parent(store)) == ["calling"]

      fail_child(store, 1)

      assert leaves(reload_parent(store)) == ["approved"]

      assert [first, second, third] = answered(store)
      assert first == %{"index" => 0, "status" => "completed", "donedata" => "item-0"}
      assert second["status"] == "failed"
      assert second["failure"]["reason"] == "child-refused"
      assert third == %{"index" => 2, "status" => "cancelled"}

      assert {:ok, record} = Storage.fetch_run(store, Linkage.child_run_id("run_1", "call", 2))
      assert record.status == :cancelled
    end

    # sabotage: in Driver.unstarted_indices/2, build the started set from
    # 0..child_count - 1 rather than from the projection -> red, the
    # canceller was handed [] and this assert_received timed out. Verified
    # red, reverted.
    test "first_error reports the never-started indices to the scheduler's seam", %{store: store} do
      parent = start_parent(store)

      # Only 0 and 1 ever got a run: index 2's start job is still sitting
      # in the scheduler's queue, so nothing here can see it.
      assert :ok =
               Driver.start_child_at(parent, "run_1", effect("item-0"), 0, 3,
                 policy: :first_error
               )

      assert :ok =
               Driver.start_child_at(parent, "run_1", effect("item-1"), 1, 3,
                 policy: :first_error
               )

      finish_child(store, 0)
      fail_child(store, 1)

      assert_received {:cancel_unstarted, "run_1", "call", [2]}

      assert leaves(reload_parent(store)) == ["approved"]
      assert [_first, _second, third] = answered(store)
      assert third == %{"index" => 2, "status" => "cancelled"}
    end

    # sabotage: in Driver.answer_parent/3, drop the `child_count: nil`
    # clause -> red, this re-delivery answered the parent's door a second
    # time with one child's donedata instead of settling. Verified red,
    # reverted.
    test "re-settling the last child answers once and the second is discarded", %{store: store} do
      parent = start_parent(store)
      start_children(parent, 2)

      finish_child(store, 0)
      finish_child(store, 1)

      assert leaves(reload_parent(store)) == ["approved"]
      first_answer = answered(store)

      # The crash-and-re-drive shape: the same terminal child settles
      # again, from a driver that has not seen the parent move.
      child_run_id = Linkage.child_run_id("run_1", "call", 1)

      assert :ok =
               Driver.answer_parent(parent_driver(store), child_run_id, {:done, "item-1"})

      assert leaves(reload_parent(store)) == ["approved"]
      assert answered(store) == first_answer
    end

    # sabotage: in Driver.answer_parent/3, drop the fan-out clause so
    # every linkage answers the parent's door directly -> red, this
    # explicit call completed the invocation on one child and the answer
    # was that child's donedata rather than the dense list. Verified red,
    # reverted.
    test "answer_parent/3 settles a fan-out child rather than answering the door", %{
      store: store
    } do
      parent = start_parent(store)
      start_children(parent, 2)

      child_run_id = Linkage.child_run_id("run_1", "call", 0)

      assert :ok =
               Driver.answer_parent(parent_driver(store), child_run_id, {:done, "explicit"})

      assert leaves(reload_parent(store)) == ["calling"]
    end
  end

  # Drives the parent to the rest point a fan-out starts from: the
  # invocation is live and answered `:pending`, and no child exists yet -
  # the scheduler's jobs are what create them.
  defp start_parent(store) do
    driver = driver(store, @parent_source, fn "myapp:map", _params, _context -> :pending end)
    {:ok, _run, _machine_state} = Driver.create(driver, "run_1")
    driver
  end

  # A dispatch fun for the single-child regression case: answers the
  # ordinary subchart instruction, which creates one child inside the
  # parent's own step.
  defp subchart_dispatch do
    fn "myapp:map", _params, %{invoke_id: invoke_id} ->
      invoke = %{effect() | invoke_id: invoke_id}
      {:start_child, invoke, {:invoke, invoke}}
    end
  end

  # The resolved `<invoke>` a scheduler hands back to `start_child_at/6`:
  # the child chart as `content`, which `Statifier.Invoke.Source` compiles,
  # and `params` carrying this index's item - what a `core.map` handler
  # seeds a child with.
  defp effect(item \\ nil) do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: %{"item" => item},
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end

  # Starts `count` children of "run_1" under one policy.
  defp start_children(driver, count, opts \\ []) do
    for index <- 0..(count - 1) do
      assert :ok =
               Driver.start_child_at(
                 driver,
                 "run_1",
                 effect("item-#{index}"),
                 index,
                 count,
                 opts
               )
    end
  end

  # Drives child `index` to its final state. Its own drive is what routes
  # the completion into the settlement, with no explicit call at all.
  defp finish_child(store, index) do
    child_run_id = Linkage.child_run_id("run_1", "call", index)

    assert {:ok, _run, _machine_state} =
             Driver.send_event(child_driver(store), child_run_id, Event.external("go"))

    :ok
  end

  # A child whose run has failed: `Runs.fail/4` is the host-driven
  # terminal transition (ADR-0004 decision 6), and the answer that follows
  # it goes through the same public door a host without a chart resolver
  # uses.
  defp fail_child(store, index) do
    child_run_id = Linkage.child_run_id("run_1", "call", index)

    assert {:ok, _run} = Runs.fail(store, child_run_id, "child-refused")

    assert :ok =
             Driver.answer_parent(
               parent_driver(store),
               child_run_id,
               {:failed, reason: "child-refused"}
             )

    :ok
  end

  # A driver over a child's chart that can reach the parent's: the shape
  # every node answering a durable child automatically has.
  defp child_driver(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)

    driver(store, @child_source, fn _type, _params, _context -> :pending end,
      chart_resolver: parent_resolver(parent_machine),
      child_canceller: recording_canceller()
    )
  end

  # The explicit door's shape: a driver built over the PARENT's own chart,
  # which is what `Driver.answer_parent/3` documents a host without a
  # chart resolver to pass.
  defp parent_driver(store) do
    driver(store, @parent_source, fn _type, _params, _context -> :pending end,
      child_canceller: recording_canceller()
    )
  end

  defp reload_parent(store) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)
    {:ok, machine_state} = Storage.load_run_position(store, "run_1", parent_machine)
    machine_state
  end

  # The assembled list, read off the parent's own persisted `_event`: the
  # answer arrived as `done.invoke.call`'s data, which is where a chart
  # reads it too.
  defp answered(store) do
    store |> reload_parent() |> Map.fetch!(:datamodel) |> get_in(["_event", "data"])
  end

  # A `chart_resolver:` that answers the parent's own content hash and
  # refuses every other.
  defp parent_resolver(parent_machine) do
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end

  defp recording_canceller do
    test = self()

    fn parent_run_id, invoke_id, indices ->
      send(test, {:cancel_unstarted, parent_run_id, invoke_id, indices})
      :ok
    end
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end

  defp driver(store, source, dispatch, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [dispatch: dispatch, invoke_types: InvokeTypes.new(types: ["myapp:map"])],
        opts
      )
    )
  end
end
