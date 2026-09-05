defmodule StatifierPersistence.DriverFanoutTest do
  @moduledoc """
  Tier A fan-out (sp-t57): `StatifierPersistence.Driver.start_child_at/6`
  starts child `i` of `N` with the count and the aggregation policy on its
  linkage, and refuses at open on a store that could not settle the
  invocation afterwards.
  """

  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory

  alias StatifierPersistence.Test.{
    NoChildListingAdapter,
    NoRunOutcomeAdapter,
    NoRunStatesAdapter
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

  # A child that completes with donedata on "go".
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="done"/>
      </state>
      <final id="done">
          <donedata><content expr="'child-result'"/></donedata>
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
  # the child chart as `content`, which `Statifier.Invoke.Source` compiles.
  defp effect do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: nil,
      content: @child_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
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
