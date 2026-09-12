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
  alias StatifierPersistence.{Driver, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage.InMemory

  alias StatifierPersistence.Test.LockOrderRecorder
  alias StatifierPersistence.Test.OutcomeWindowSerialization

  alias StatifierPersistence.Test.{
    NoChildListingAdapter,
    NoExecutionOutcomeAdapter,
    NoExecutionStatesAdapter,
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
  #
  # On "refuse" it instead reaches a failure-classed final - a <final>
  # whose <donedata> carries the reserved `statifier_persistence:execution_status`
  # key set to "failed" (ADR-0008's 2026-09-06 amendment). That is the
  # chart saying *this one finished badly* in its own words, with no host
  # translation: the child's own drive takes the execution to :failed, and the
  # automatic answer carries it into the settlement.
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <datamodel><data id="item"/></datamodel>
      <state id="idle">
          <transition event="go" target="done"/>
          <transition event="refuse" target="refused"/>
      </state>
      <final id="done">
          <donedata><content expr="item"/></donedata>
      </final>
      <final id="refused">
          <donedata>
              <param name="statifier_persistence:execution_status" expr="'failed'"/>
              <param name="item" expr="item"/>
          </donedata>
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
    # index-0 execution id and the second create adopted the first, so the
    # index-1 fetch below returned :execution_not_found. Verified red, reverted.
    test "creates child i of N with the count and policy on its linkage", %{store: store} do
      driver = start_parent(store)

      assert :ok = Driver.start_child_at(driver, "execution_1", effect(), 0, 3)

      assert :ok =
               Driver.start_child_at(driver, "execution_1", effect(), 2, 3, policy: :first_error)

      assert {:ok, first} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 0)
               )

      assert {:ok, third} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 2)
               )

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

    # sabotage: in Driver.create_child/6, treat {:error, :execution_exists} as an
    # ordinary refusal (drop the adopt_child/3 clause) -> red, the second
    # call answered {:refused, :execution_exists} instead of :ok. Verified red,
    # reverted.
    test "a re-delivered start job for the same index adopts rather than duplicating", %{
      store: store
    } do
      driver = start_parent(store)

      assert :ok = Driver.start_child_at(driver, "execution_1", effect(), 1, 3)
      child_execution_id = Linkage.child_execution_id("execution_1", "call", 1)
      assert {:ok, first} = Storage.fetch_execution(store, child_execution_id)

      assert :ok = Driver.start_child_at(driver, "execution_1", effect(), 1, 3)

      assert {:ok, second} = Storage.fetch_execution(store, child_execution_id)
      assert second == first
    end

    # The bound is Linkage.new/6's, and this asserts start_child_at/6
    # reaches it rather than swallowing it.
    #
    # sabotage: in Linkage.new/6, compare child_index against
    # child_count + 1 -> red, index 3 of 3 was accepted here and in
    # execution_linkage_test's own bound case. Verified red, reverted.
    test "an index outside 0..count - 1 raises" do
      {:ok, store} = Storage.new(InMemory, [])
      driver = start_parent(store)

      assert_raise ArgumentError, fn ->
        Driver.start_child_at(driver, "execution_1", effect(), 3, 3)
      end
    end

    # sabotage: in Driver.start_context/3, ignore the fetch_execution/2 refusal
    # and build the context anyway -> red, the call answered :ok and
    # created a child linked to a parent that does not exist. Verified
    # red, reverted.
    test "a parent id naming no stored execution refuses :execution_not_found", %{store: store} do
      driver = start_parent(store)

      assert {:refused, :execution_not_found} =
               Driver.start_child_at(driver, "execution_missing", effect(), 0, 1)
    end

    # sabotage: in Driver.settleable/4, collapse the three cond arms to the
    # child-listing one -> red, the outcome and projection adapters both
    # started a child instead of refusing. Verified red, reverted.
    test "refuses at open on a store that could not settle the invocation" do
      for {adapter, reason} <- [
            {NoChildListingAdapter, :child_listing_unsupported},
            {NoExecutionOutcomeAdapter, :execution_outcome_unsupported},
            {NoExecutionStatesAdapter, :execution_states_unsupported}
          ] do
        {:ok, store} = Storage.new(adapter, [])
        driver = start_parent(store)

        assert {:refused, ^reason} = Driver.start_child_at(driver, "execution_1", effect(), 0, 2),
               "expected #{inspect(adapter)} to refuse with #{inspect(reason)}"

        assert {:error, :execution_not_found} =
                 Storage.fetch_execution(
                   store,
                   Linkage.child_execution_id("execution_1", "call", 0)
                 )
      end
    end

    # sabotage: in Driver.child_linkage/3, make the nil clause build a
    # fan-out linkage of one (Linkage.new/6 with 1 and :all) -> red, the
    # single-child path's stored metadata grew the two keys and this
    # assertion saw child_count 1 instead of nil. Verified red, reverted.
    test "the single-child subchart path records neither value", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch())

      assert {:ok, _execution, _machine_state} = Driver.create(driver, "execution_single")

      assert {:ok, record} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_single", "call", 0)
               )

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
                 "execution_1",
                 {:start_child, invoke, {:invoke, invoke}},
                 0,
                 1
               )

      assert {:ok, _record} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 0)
               )
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

      # Index 2 is still in the scheduler's queue and has no execution at all.
      assert :ok = Driver.start_child_at(parent, "execution_1", effect("item-0"), 0, 3)
      assert :ok = Driver.start_child_at(parent, "execution_1", effect("item-1"), 1, 3)

      finish_child(store, 0)
      finish_child(store, 1)

      assert leaves(reload_parent(store)) == ["calling"]

      # It settles when the late child finally starts and finishes.
      assert :ok = Driver.start_child_at(parent, "execution_1", effect("item-2"), 2, 3)
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

    # sp-kl3, the concurrent settlement race, in its deterministic form: a
    # child's terminal STATUS is persisted by its own drive, and its answer
    # is recorded by the settlement that follows - two writes, in that
    # order. Under a concurrent queue a sibling's settlement can run in
    # between, and a settlement that judges terminality by status alone
    # finds every index terminal while an answer is still in flight.
    #
    # Driving index 0 with a resolver-less driver reproduces exactly that
    # interleaving without a race: the drive commits `completed` and
    # answers nothing, which is the state index 1's settlement would
    # observe if it won the race.
    #
    # sabotage: in Driver.entry/5, drop the pending-outcome clause so a
    # recorded-nil outcome assembles as an entry again -> red, the parent
    # left "calling" for "approved" on index 1's settlement and index 0
    # assembled with a nil donedata, which is the live defect. Verified
    # red, reverted.
    test "a completed child whose answer is still in flight does not settle the invocation", %{
      store: store
    } do
      parent = start_parent(store)
      start_children(parent, 2)

      # Index 0's drive committed `completed`; its answer has not been
      # recorded yet.
      finish_child_without_answering(store, 0)
      finish_child(store, 1)

      assert leaves(reload_parent(store)) == ["calling"]

      # The in-flight answer lands, and its own settlement is the one that
      # sees both answers and assembles.
      assert :ok =
               Driver.answer_parent(
                 parent_driver(store),
                 Linkage.child_execution_id("execution_1", "call", 0),
                 {:done, "item-0"}
               )

      assert leaves(reload_parent(store)) == ["approved"]

      assert answered(store) == [
               %{"index" => 0, "status" => "completed", "donedata" => "item-0"},
               %{"index" => 1, "status" => "completed", "donedata" => "item-1"}
             ]
    end

    # sp-kl3's other half, the ordering one: the answer is recorded inside
    # the parent's exclusion, not before it. That is what makes the
    # settlement that records the last answer the settlement that sees
    # them all, rather than leaving it to how two separate writes happen
    # to interleave with two separate reads.
    #
    # sabotage: in Driver.decide/4, move record_outcome/3 back out of the
    # `with_execution` callback and into settle_child/4 ahead of it -> red, the
    # answer was already stored when the settlement's exclusion opened.
    # Verified red, reverted.
    test "a child's answer is recorded inside the parent's exclusion", %{store: store} do
      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)
      strategy = {OutcomeWindowSerialization, {self(), store, child_execution_id}}

      parent = start_parent(store)
      start_children(parent, 1)

      finish_child(store, 0, serialization: strategy)

      assert leaves(reload_parent(store)) == ["approved"]

      assert_receive {:exclusion, "execution_1", false, true}
    end

    # Scoped to the settlement's own question. The listing is legitimately
    # used elsewhere on this path - the parent's exit from the invoking
    # state cascades a cancel over the invocation, which walks records
    # (ADR-0008 decision 5) - so this drives the two settlements that
    # answer nothing and stops before the one that answers.
    #
    # sabotage: in Driver.settle/3, ask Storage.list_executions_by_metadata/2
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

      assert {:ok, record} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 2)
               )

      assert record.status == :cancelled
    end

    # The seam ADR-0008's 2026-09-06 amendment closes, end to end: no
    # Executions.fail/4, no Driver.answer_parent/3, no host in the loop at all.
    # The child's own drive reads the tag off its final's <donedata>,
    # persists :failed with "failed_final", and the driver's automatic
    # path answers the parent - which is what makes first_error fire.
    # Campaign 031's fan-out proof had to translate this host-side; that
    # translation is what this case makes unnecessary.
    #
    # sabotage: in Executions.execution_status/2, drop the failure_classed_final?/1
    # arm -> red, child 1 completed, the settlement waited for child 2,
    # and the parent stayed in "calling". Verified red, reverted.
    test "a chart-authored failure cancels a live sibling with no host translation",
         %{store: store} do
      parent = start_parent(store)
      start_children(parent, 3, policy: :first_error)

      finish_child(store, 0)
      assert leaves(reload_parent(store)) == ["calling"]

      refuse_child(store, 1)

      assert leaves(reload_parent(store)) == ["approved"]

      assert [first, second, third] = answered(store)
      assert first == %{"index" => 0, "status" => "completed", "donedata" => "item-0"}
      assert second["status"] == "failed"
      assert second["failure"]["reason"] == "failed_final"
      assert third == %{"index" => 2, "status" => "cancelled"}

      assert {:ok, record} =
               Storage.fetch_execution(
                 store,
                 Linkage.child_execution_id("execution_1", "call", 1)
               )

      assert record.status == :failed
      assert record.failure == "failed_final"
    end

    # sabotage: in Driver.unstarted_indices/2, build the started set from
    # 0..child_count - 1 rather than from the projection -> red, the
    # canceller was handed [] and this assert_received timed out. Verified
    # red, reverted.
    test "first_error reports the never-started indices to the scheduler's seam", %{store: store} do
      parent = start_parent(store)

      # Only 0 and 1 ever got an execution: index 2's start job is still sitting
      # in the scheduler's queue, so nothing here can see it.
      assert :ok =
               Driver.start_child_at(parent, "execution_1", effect("item-0"), 0, 3,
                 policy: :first_error
               )

      assert :ok =
               Driver.start_child_at(parent, "execution_1", effect("item-1"), 1, 3,
                 policy: :first_error
               )

      finish_child(store, 0)
      fail_child(store, 1)

      assert_received {:cancel_unstarted, "execution_1", "call", [2]}

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
      child_execution_id = Linkage.child_execution_id("execution_1", "call", 1)

      assert :ok =
               Driver.answer_parent(parent_driver(store), child_execution_id, {:done, "item-1"})

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

      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)

      assert :ok =
               Driver.answer_parent(parent_driver(store), child_execution_id, {:done, "explicit"})

      assert leaves(reload_parent(store)) == ["calling"]
    end

    # sp-y7n: the outside-fail answer reaches `answer_parent/3` too, so a
    # fan-out child failed through `Executions.fail/4` settles rather than
    # completing the invocation on one child's failure.
    #
    # sabotage: had `Driver.answer_resolved/4`'s no-resolver clause call
    # `respond_to_parent/3` directly instead of `answer_parent/3`, which is
    # where the fan-out routing lives - red, this case alone: the one
    # child's failure answered the parent's door and it left "calling".
    # Verified red, reverted.
    test "Executions.fail/4 with driver: settles a fan-out child rather than answering", %{
      store: store
    } do
      parent = start_parent(store)
      start_children(parent, 2)

      child_execution_id = Linkage.child_execution_id("execution_1", "call", 0)

      assert {:ok, _execution} =
               Executions.fail(store, child_execution_id, "boom", driver: parent_driver(store))

      assert leaves(reload_parent(store)) == ["calling"]
    end
  end

  describe "lock acquisition order" do
    # sp-oq4's audit, pinned. Under `first_error` the settlement holds the
    # PARENT's exclusion (`Driver.decide/4`) and the cascade writes the
    # siblings' rows from inside it, each under its own; meanwhile every
    # sibling's own drive holds that same sibling's exclusion. Two
    # connections, two lock sets, and the one place on this path where a
    # lock-order cycle is conceivable at all.
    #
    # It is not reachable, and this is why: every exclusion taken while
    # another is held is taken on a STRICT DESCENDANT of the one held.
    # `Linkage.child_execution_id/3` makes a child's execution id strictly extend its
    # parent's, so "descendant" is a prefix test and the execution tree is
    # acyclic by construction (ADR-0008 decision 6) - a wait-for relation
    # that only ever executions parent-to-child down an acyclic tree has no
    # cycle in it, on Postgres advisory locks or anywhere else.
    #
    # The upward acquisition - a child answering its parent - is the case
    # that would close a cycle, and it is taken with NOTHING held: the
    # child's own drive commits and releases its own exclusion before
    # `maybe_answer_parent/3` executions, and `settle_child/4` answers the
    # parent's door after `decide/4`'s exclusion has closed, not inside
    # it. Assertion (3) is what pins that.
    #
    # Both sabotages below fail this case by HANGING rather than by
    # tripping an assert, which is the finding rather than a weakness in
    # them: `Storage.InMemory.lock_execution/3` is not reentrant, so an
    # acquisition that is not on a strict descendant is one that can name
    # an execution this process already holds - and then it waits for itself.
    # That is the shape of the cycle this case exists to rule out, drawn
    # inside one process because a single connection is where it is
    # reproducible.
    #
    # sabotage: in Driver.decide/4, take the exclusion on `child_execution_id`
    # instead of `linkage.parent_execution_id` -> red, the cascade's own cancel
    # of index 1 asked for the exclusion the settlement was already
    # holding and the case timed out inside Executions.cascade_cancel/3.
    # Verified red, reverted.
    # sabotage: in Driver.record_and_settle/5, answer the parent's door
    # from inside the settlement's own exclusion (respond_to_parent/3 on
    # the assembled answer) rather than from settle_child/4 after it
    # closes -> red, `reenter/5` asked for "execution_1" while "execution_1" was held
    # and the case timed out. Verified red, reverted.
    test "every nested exclusion is taken on a strict descendant of the one held", %{
      store: store
    } do
      strategy = {LockOrderRecorder, {self(), store}}

      parent = start_parent(store)
      start_children(parent, 3, policy: :first_error)

      finish_child(store, 0, serialization: strategy)
      refuse_child(store, 1, serialization: strategy)

      assert leaves(reload_parent(store)) == ["approved"]

      acquisitions =
        for {:acquire, execution_id, held} <- LockOrderRecorder.trace(), do: {execution_id, held}

      # (1) The direction, over every acquisition the execution made.
      upward =
        for {execution_id, held} <- acquisitions,
            holder <- held,
            not String.starts_with?(execution_id, holder <> "/"),
            do: {holder, execution_id}

      assert upward == []

      # (2) Not vacuous: the settlement really does nest, so (1) is a
      # statement about a relation that exists.
      assert {Linkage.child_execution_id("execution_1", "call", 2), ["execution_1"]} in acquisitions

      # (3) Every acquisition of the PARENT's exclusion is taken holding
      # nothing - the child's own exclusion is already closed, so no
      # connection ever holds a child and waits for its parent.
      parent_acquisitions = for {"execution_1", held} <- acquisitions, do: held

      assert parent_acquisitions != []
      assert Enum.all?(parent_acquisitions, &(&1 == []))
    end
  end

  # Drives the parent to the rest point a fan-out starts from: the
  # invocation is live and answered `:pending`, and no child exists yet -
  # the scheduler's jobs are what create them.
  defp start_parent(store) do
    driver = driver(store, @parent_source, fn "myapp:map", _params, _context -> :pending end)
    {:ok, _execution, _machine_state} = Driver.create(driver, "execution_1")
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

  # Starts `count` children of "execution_1" under one policy.
  defp start_children(driver, count, opts \\ []) do
    for index <- 0..(count - 1) do
      assert :ok =
               Driver.start_child_at(
                 driver,
                 "execution_1",
                 effect("item-#{index}"),
                 index,
                 count,
                 opts
               )
    end
  end

  # Drives child `index` to its final state. Its own drive is what routes
  # the completion into the settlement, with no explicit call at all.
  defp finish_child(store, index, opts \\ []) do
    child_execution_id = Linkage.child_execution_id("execution_1", "call", index)

    assert {:ok, _execution, _machine_state} =
             Driver.send_event(
               child_driver(store, opts),
               child_execution_id,
               Event.external("go")
             )

    :ok
  end

  # Drives child `index` to its final state through a driver with no
  # `chart_resolver:`, so the drive persists the terminal status and the
  # automatic answer no-ops (`Driver.auto_answer_parent/3`'s nil clause).
  # That is the half-written picture a sibling's settlement can observe
  # under a concurrent queue, held still.
  defp finish_child_without_answering(store, index) do
    child_execution_id = Linkage.child_execution_id("execution_1", "call", index)

    resolverless =
      driver(store, @child_source, fn _type, _params, _context -> :pending end,
        child_canceller: recording_canceller()
      )

    assert {:ok, execution, _machine_state} =
             Driver.send_event(resolverless, child_execution_id, Event.external("go"))

    assert execution.status == :completed

    :ok
  end

  # Drives child `index` to its failure-classed final. Deliberately the
  # same shape as `finish_child/3` and nothing more: the whole point of
  # the amendment is that a chart-authored failure needs no second call.
  defp refuse_child(store, index, opts \\ []) do
    child_execution_id = Linkage.child_execution_id("execution_1", "call", index)

    assert {:ok, %{status: :failed, failure: "failed_final"}, _machine_state} =
             Driver.send_event(
               child_driver(store, opts),
               child_execution_id,
               Event.external("refuse")
             )

    :ok
  end

  # A child whose execution has failed: `Executions.fail/4` is the host-driven
  # terminal transition (ADR-0004 decision 6), and the answer that follows
  # it goes through the same public door a host without a chart resolver
  # uses.
  defp fail_child(store, index) do
    child_execution_id = Linkage.child_execution_id("execution_1", "call", index)

    assert {:ok, _execution} = Executions.fail(store, child_execution_id, "child-refused")

    assert :ok =
             Driver.answer_parent(
               parent_driver(store),
               child_execution_id,
               {:failed, reason: "child-refused"}
             )

    :ok
  end

  # A driver over a child's chart that can reach the parent's: the shape
  # every node answering a durable child automatically has.
  defp child_driver(store, opts) do
    {:ok, parent_machine} = Statifier.compile(@parent_source)

    driver(
      store,
      @child_source,
      fn _type, _params, _context -> :pending end,
      Keyword.merge(
        [chart_resolver: parent_resolver(parent_machine), child_canceller: recording_canceller()],
        opts
      )
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
    {:ok, machine_state} = Storage.load_execution_position(store, "execution_1", parent_machine)
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

    fn parent_execution_id, invoke_id, indices ->
      send(test, {:cancel_unstarted, parent_execution_id, invoke_id, indices})
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
