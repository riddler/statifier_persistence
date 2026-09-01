defmodule StatifierPersistence.DriverSubchartTest do
  @moduledoc """
  The `start_child` clause on `StatifierPersistence.Driver` (ADR-0008
  decision 3, sp-nt8 Phase 3): `:dispatch` answering
  `{:start_child, invoke, {:invoke, invoke}}` creates the child as an
  ordinary run under the parent's own exclusion, links it under the
  reserved metadata namespace, and rests the parent at `:pending` with the
  invocation live.
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Runs, Storage}
  alias StatifierPersistence.Run.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.NoChildListingAdapter

  # One durable subchart invocation, with a way out that is not the
  # answer: "timeout" exits "calling" without a `done.invoke.call`. Phase 3
  # never answers the parent (that is Phase 4), so this fixture only needs
  # to prove the child was created and the parent rested.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
      <state id="abandoned"/>
  </scxml>
  """

  # A plain two-state child with no invoke of its own - the leaf a nested
  # subtree bottoms out at.
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" target="settled"/>
      </state>
      <state id="settled"/>
  </scxml>
  """

  # The document id a resolving handler looks the child chart up by. It is
  # an opaque string to this package: the core never dereferences `src`
  # (st-ADR-0031).
  @document_id "chart://approval/v3"

  # `@parent_source` with the document id on the element, and a refusal
  # transition to land on when it cannot be resolved.
  @src_parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart" src="chart://approval/v3"/>
          <transition event="done.invoke.call" target="approved"/>
          <transition event="error.communication.invoke.call" target="refused"/>
      </state>
      <state id="approved"/>
      <state id="refused"/>
  </scxml>
  """

  # A child that itself starts a subchart under invoke id "nested" - the
  # fixture for decision 6's nesting case.
  @nesting_child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="nested" type="myapp:subchart"/>
          <transition event="timeout" target="abandoned"/>
      </state>
      <state id="abandoned"/>
  </scxml>
  """

  # A child that completes with donedata on "go" - Phase 4's completion
  # fixture: `@child_source` never reaches a final at all, and a completion
  # test needs one that does.
  @child_done_source """
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

  describe "start_child from a document id" do
    # The shape a `statifier_blocks` durable subchart handler has: the
    # child chart is not known to the handler, it is looked up by the
    # `<invoke>`'s own `src` (sb-ADR-0008 decision 2's resolver contract),
    # which reaches the dispatch fun only through
    # `t:Driver.dispatch_context/0`'s `:invoke` key (ADR-0007 decision 5's
    # amendment, sp-2yx). Before that key this could not be written at all.
    #
    # Sabotage: dropped the `:invoke` key from `perform/5`'s `Map.merge`
    # (driver.ex) - the dispatch fun's `%{invoke: ...}` clause no longer
    # matched and the create raised FunctionClauseError, which is the
    # honest failure: there is no other way to reach `src`.
    test "a handler resolves the child by the invoke's src", %{store: store} do
      driver =
        driver(store, @src_parent_source, resolving_dispatch(%{@document_id => @child_source}))

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")

      assert leaves(machine_state) == ["calling"]

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      assert {:ok, run_record} = Storage.fetch_run(store, child_run_id)
      assert run_record.status == :active

      assert {:ok, linkage} = Linkage.from_metadata(run_record.metadata)
      {:ok, child_machine} = Statifier.compile(@child_source)
      assert linkage.content_hash == Machine.identity(child_machine).content_hash
    end
  end

  describe "start_child" do
    # Sabotage: had `create_child/5` return `:ok` without calling `create/3`
    # at all (the child-exists case's mirror) - the run was never inserted
    # and `Storage.fetch_run/2` on the derived id returned `{:error,
    # :run_not_found}`.
    test "the child run exists under the derived id after the parent's create", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)

      assert {:ok, run_record} = Storage.fetch_run(store, child_run_id)
      assert run_record.status == :active
    end

    # Sabotage: dropped `content_hash` out of `create_child/5`'s call to
    # `Linkage.new/4` by passing `nil` - the pin case: the stored linkage no
    # longer carries the child's own identity, and this assertion caught
    # the missing value directly rather than through a downstream failure.
    test "the child's metadata carries all four linkage values and the pin", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      assert {:ok, run_record} = Storage.fetch_run(store, child_run_id)
      assert {:ok, linkage} = Linkage.from_metadata(run_record.metadata)

      assert linkage.parent_run_id == "run_1"
      assert linkage.invoke_id == "call"
      assert linkage.child_index == 0

      {:ok, child_machine} = Statifier.compile(@child_source)
      assert linkage.content_hash == Machine.identity(child_machine).content_hash
    end

    # Sabotage: had the `:ok` arm of `perform/5`'s `start_child` case
    # `buffer/4` a `{:done, nil}` answer instead of returning `:ok` - the
    # parent took the `done.invoke.call` transition and rested in
    # "approved" instead of "calling".
    test "the parent is at rest with the invocation live", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))

      assert {:ok, _run, _machine_state} = Driver.create(driver, "run_1")

      {:ok, parent_machine} = Statifier.compile(@parent_source)
      assert {:ok, reloaded} = Storage.load_run_position(store, "run_1", parent_machine)

      assert leaves(reloaded) == ["calling"]
      assert Map.values(reloaded.active_invocations) == ["call"]
    end

    # Sabotage: treated `{:error, :run_exists}` as any other refusal in
    # `create_child/5` (removed the `adopt_child/3` clause) - the re-drive
    # refused with `child_run_creation_failed` (the parent landed in
    # "refused") instead of resting normally in "calling", and this
    # assertion on the parent's leaf went red.
    test "a second identical drive does not create a second run and does not refuse", %{
      store: store
    } do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))
      child_run_id = Linkage.child_run_id("run_1", "call", 0)

      {:ok, child_machine} = Statifier.compile(@child_source)
      content_hash = Machine.identity(child_machine).content_hash
      linkage = Linkage.new("run_1", "call", 0, content_hash)

      # Simulates the crash window ADR-0004 decision 3 names: the child
      # from an earlier, interrupted attempt already exists under the
      # derived id, with the matching linkage, when the parent's own
      # `create/3` re-drives from a driver that has never seen either run.
      assert {:ok, _run, _machine_state} =
               StatifierPersistence.Runs.create(store, child_run_id, child_machine,
                 executor: fn _effect, _context -> :ok end,
                 linkage: linkage
               )

      assert {:ok, pre_redrive} = Storage.fetch_run(store, child_run_id)

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")

      assert leaves(machine_state) == ["calling"]
      assert Map.values(machine_state.active_invocations) == ["call"]

      # Not created a second time: the fetched record is byte-identical to
      # what the pre-existing child already held.
      assert {:ok, post_redrive} = Storage.fetch_run(store, child_run_id)
      assert post_redrive == pre_redrive
    end

    # Sabotage: had `resolve_child/3` swallow the compile error and return
    # `:ok` unconditionally - the refusal never fired and this assertion on
    # `error.communication.invoke.call`'s reason went red.
    test "an unresolvable content refuses with child_run_creation_failed", %{store: store} do
      driver = driver(store, @parent_source, subchart_dispatch("<not scxml at all"))

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")

      assert leaves(machine_state) == ["refused"]

      assert machine_state.datamodel["_event"]["data"]["reason"] == "child_run_creation_failed"
    end

    # Sabotage: dropped the `Storage.child_listing_supported?/1` pre-check
    # from `start_child/3` - the child was created anyway against an
    # adapter that cannot enumerate it, and this assertion on "no child
    # written" went red (the run existed under the derived id).
    test "a store whose adapter cannot enumerate children refuses and writes no child" do
      {:ok, store} = Storage.new(NoChildListingAdapter, [])
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")

      assert leaves(machine_state) == ["refused"]
      assert machine_state.datamodel["_event"]["data"]["reason"] == "child_run_creation_failed"

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      assert {:error, :run_not_found} = Storage.fetch_run(store, child_run_id)
    end

    # Sabotage: had `create_child/5` drive the child through a bare
    # `Runs.create/4` call (a no-op executor) instead of this module's own
    # `create/3` - the child's own `<invoke>` never reached `:dispatch`, no
    # grandchild was created, and `fetch_run/2` on the grandchild id went
    # red on `:run_not_found`.
    test "a child that itself invokes a grandchild produces a three-run tree", %{store: store} do
      driver = driver(store, @parent_source, nesting_dispatch())

      assert {:ok, _run, machine_state} = Driver.create(driver, "run_1")
      assert leaves(machine_state) == ["calling"]

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      grandchild_run_id = Linkage.child_run_id(child_run_id, "nested", 0)

      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert {:ok, grandchild_record} = Storage.fetch_run(store, grandchild_run_id)

      assert {:ok, child_linkage} = Linkage.from_metadata(child_record.metadata)
      assert child_linkage.parent_run_id == "run_1"
      assert child_linkage.invoke_id == "call"

      assert {:ok, grandchild_linkage} = Linkage.from_metadata(grandchild_record.metadata)
      assert grandchild_linkage.parent_run_id == child_run_id
      assert grandchild_linkage.invoke_id == "nested"
    end
  end

  describe "completion" do
    # Sabotage: had `done_effect/1` return `nil` unconditionally - the
    # assertion `run.donedata == "child-result"` went red (got `nil`).
    test "a run that reaches a top-level final with donedata carries it on run.donedata", %{
      store: store
    } do
      {:ok, machine} = Statifier.compile(@child_done_source)
      driver = Driver.new(store, machine, dispatch: fn _type, _params, _ctx -> :pending end)

      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")
      assert {:ok, run, _ms} = Driver.send_event(driver, "run_1", Event.external("go"))

      assert run.status == :completed
      assert run.donedata == "child-result"
    end

    # Sabotage: in `respond_to_parent/3`'s `{:done, donedata}` clause,
    # called `done_invocation(driver, run_id, ...)` (the *child's* own run
    # id) instead of `linkage.parent_run_id` - `Storage.load_run_position/3`
    # on "run_1" still showed "calling" and the assertion on `leaves/1` went
    # red.
    test "with a chart_resolver, completing the child moves the parent and carries donedata", %{
      store: store
    } do
      {:ok, parent_machine} = Statifier.compile(@parent_source)
      {:ok, child_machine} = Statifier.compile(@child_done_source)
      resolver = parent_resolver(parent_machine)

      driver =
        driver(store, @parent_source, subchart_dispatch(@child_done_source),
          chart_resolver: resolver
        )

      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      child_driver = %{driver | machine: child_machine}

      assert {:ok, child_run, _child_ms} =
               Driver.send_event(child_driver, child_run_id, Event.external("go"))

      assert child_run.status == :completed
      assert child_run.donedata == "child-result"

      assert {:ok, parent_reloaded} = Storage.load_run_position(store, "run_1", parent_machine)
      assert leaves(parent_reloaded) == ["approved"]
      assert parent_reloaded.datamodel["_event"]["data"] == "child-result"
    end

    # Sabotage: dropped the `chart_resolver: nil` guard clause from
    # `auto_answer_parent/3`, so it always tried `driver.chart_resolver.(...)`
    # - this test's driver has none, and the child's own `send_event/4` call
    # raised `BadFunctionError` instead of completing quietly.
    test "without a chart_resolver, the parent is untouched and parent_link/2 works", %{
      store: store
    } do
      driver = driver(store, @parent_source, subchart_dispatch(@child_done_source))

      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      {:ok, child_machine} = Statifier.compile(@child_done_source)
      child_driver = %{driver | machine: child_machine}

      assert {:ok, child_run, _child_ms} =
               Driver.send_event(child_driver, child_run_id, Event.external("go"))

      assert child_run.status == :completed

      {:ok, parent_machine} = Statifier.compile(@parent_source)
      assert {:ok, parent_reloaded} = Storage.load_run_position(store, "run_1", parent_machine)
      assert leaves(parent_reloaded) == ["calling"]
      assert Map.values(parent_reloaded.active_invocations) == ["call"]

      assert {:ok, linkage} = Driver.parent_link(store, child_run_id)
      assert linkage.parent_run_id == "run_1"
      assert linkage.invoke_id == "call"
    end

    # Sabotage: in `respond_to_parent/3`'s `{:failed, failure}` clause,
    # called `done_invocation/4` instead of `failed_invocation/4` - the
    # parent took `done.invoke.call` and rested in "approved" instead of
    # "refused", and the assertion on `leaves/1` went red.
    test "answer_parent/3 answers a failed child through the failing door with reason set", %{
      store: store
    } do
      {:ok, parent_machine} = Statifier.compile(@parent_source)
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))

      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      assert {:ok, _run} = Runs.fail(store, child_run_id, "boom")

      parent_driver = %{driver | machine: parent_machine}

      assert {:ok, _run, machine_state} =
               Driver.answer_parent(parent_driver, child_run_id, {:failed, reason: "boom"})

      assert leaves(machine_state) == ["refused"]
      assert machine_state.datamodel["_event"]["data"]["reason"] == "boom"
    end

    # Sabotage: in `auto_answer_parent/3`'s live clause, replaced the
    # `resolve_and_answer/4` call with a bare `:ok` (skipping
    # `answer_parent/3` entirely) - the parent stayed in "calling" and the
    # assertion on `leaves/1` == `["approved"]` went red.
    test "the completion path works across a restart, with a driver that has seen neither run", %{
      store: store
    } do
      {:ok, parent_machine} = Statifier.compile(@parent_source)
      {:ok, child_machine} = Statifier.compile(@child_done_source)
      resolver = parent_resolver(parent_machine)

      driver =
        driver(store, @parent_source, subchart_dispatch(@child_done_source),
          chart_resolver: resolver
        )

      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)

      # A cold node: a fresh driver over only the child's own chart, built
      # with no knowledge of the parent's run or the drive that started it -
      # only the store and the chart_resolver.
      cold_driver =
        Driver.new(store, child_machine,
          dispatch: fn _type, _params, _ctx -> :pending end,
          chart_resolver: resolver
        )

      assert {:ok, child_run, _ms} =
               Driver.send_event(cold_driver, child_run_id, Event.external("go"))

      assert child_run.status == :completed
      assert child_run.donedata == "child-result"

      assert {:ok, parent_reloaded} = Storage.load_run_position(store, "run_1", parent_machine)
      assert leaves(parent_reloaded) == ["approved"]
      assert parent_reloaded.datamodel["_event"]["data"] == "child-result"
    end
  end

  describe "cascading cancel" do
    # Sabotage: had the `{:cancel_invoke, _}` clause in `perform/5` return
    # `:ok` unconditionally, never calling `Runs.cascade_cancel/3` - the
    # child's status stayed `:active` after the parent's timeout and this
    # assertion went red.
    test "a parent that times out leaves the child cancelled with its position unchanged", %{
      store: store
    } do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      assert {:ok, before_cancel} = Storage.fetch_run(store, child_run_id)
      assert before_cancel.status == :active

      assert {:ok, _run, machine_state} =
               Driver.send_event(driver, "run_1", Event.external("timeout"))

      assert leaves(machine_state) == ["abandoned"]

      assert {:ok, after_cancel} = Storage.fetch_run(store, child_run_id)
      assert after_cancel.status == :cancelled
      assert after_cancel.position_blob == before_cancel.position_blob
    end

    # Sabotage: in `cancel_and_descend/3`, dropped the recursive
    # `cascade_cancel(store, Linkage.parent_match(run_id), opts)` call (only
    # the top-level record was ever cancelled) - the grandchild's status
    # stayed `:active` and this assertion went red.
    test "a three-deep tree is fully cancelled from one parent timeout", %{store: store} do
      driver = driver(store, @parent_source, nesting_dispatch())
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      grandchild_run_id = Linkage.child_run_id(child_run_id, "nested", 0)

      assert {:ok, _run, machine_state} =
               Driver.send_event(driver, "run_1", Event.external("timeout"))

      assert leaves(machine_state) == ["abandoned"]

      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert {:ok, grandchild_record} = Storage.fetch_run(store, grandchild_run_id)
      assert child_record.status == :cancelled
      assert grandchild_record.status == :cancelled
    end

    # Sabotage: in `cancel_counted/3`, called `Storage.update_run_status/4`
    # with `:cancelled` unconditionally instead of `cancel/3` - a re-run
    # over an already-cancelled subtree then counted every run again
    # instead of discarding, and the `{:ok, 0}` assertion went red (got
    # `{:ok, 2}`).
    test "re-running the cascade over an already-cancelled subtree writes nothing", %{
      store: store
    } do
      driver = driver(store, @parent_source, nesting_dispatch())
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      assert {:ok, _run, _ms} = Driver.send_event(driver, "run_1", Event.external("timeout"))

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      grandchild_run_id = Linkage.child_run_id(child_run_id, "nested", 0)

      assert {:ok, before_child} = Storage.fetch_run(store, child_run_id)
      assert {:ok, before_grandchild} = Storage.fetch_run(store, grandchild_run_id)

      assert {:ok, 0} = Runs.cascade_cancel(store, Linkage.invocation_match("run_1", "call"))

      assert {:ok, after_child} = Storage.fetch_run(store, child_run_id)
      assert {:ok, after_grandchild} = Storage.fetch_run(store, grandchild_run_id)
      assert after_child == before_child
      assert after_grandchild == before_grandchild
    end

    # Sabotage: in `cancel_and_descend/3`, descended only when `cancel/3`
    # returned `{:ok, _}` (skipping the recursion on a `{:discarded, _}`) -
    # the hand-cancelled child's own children were never walked, the
    # grandchild stayed `:active`, and the `{:ok, 1}` assertion went red
    # (got `{:ok, 0}`).
    test "a cascade interrupted after the first level completes the rest when re-run", %{
      store: store
    } do
      driver = driver(store, @parent_source, nesting_dispatch())
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      grandchild_run_id = Linkage.child_run_id(child_run_id, "nested", 0)

      # Simulates a cascade interrupted right after the first level: the
      # child is cancelled by hand, the grandchild is not.
      assert {:ok, _run} = Runs.cancel(store, child_run_id)
      assert {:ok, grandchild_before} = Storage.fetch_run(store, grandchild_run_id)
      assert grandchild_before.status == :active

      assert {:ok, 1} = Runs.cascade_cancel(store, Linkage.invocation_match("run_1", "call"))

      assert {:ok, child_after} = Storage.fetch_run(store, child_run_id)
      assert {:ok, grandchild_after} = Storage.fetch_run(store, grandchild_run_id)
      assert child_after.status == :cancelled
      assert grandchild_after.status == :cancelled
    end

    # Sabotage: same mutation as the "writes nothing" case above
    # (`cancel_counted/3` forcing `:cancelled` unconditionally) - the
    # already-completed child was overwritten to `:cancelled` and this
    # assertion went red.
    test "a child that is already completed is left completed, not overwritten", %{
      store: store
    } do
      driver = driver(store, @parent_source, subchart_dispatch(@child_done_source))
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      child_run_id = Linkage.child_run_id("run_1", "call", 0)
      {:ok, child_machine} = Statifier.compile(@child_done_source)
      child_driver = %{driver | machine: child_machine}

      # Completes the child directly (this driver has no `chart_resolver:`,
      # so the parent is never told), so the parent still believes "call"
      # is live when it times out.
      assert {:ok, child_run, _ms} =
               Driver.send_event(child_driver, child_run_id, Event.external("go"))

      assert child_run.status == :completed

      assert {:ok, _run, machine_state} =
               Driver.send_event(driver, "run_1", Event.external("timeout"))

      assert leaves(machine_state) == ["abandoned"]

      assert {:ok, child_record} = Storage.fetch_run(store, child_run_id)
      assert child_record.status == :completed
    end

    # No sabotage note: this asserts ADR-0007 decision 3's pre-existing
    # discard mechanism (`late_answer/3`, `driver.ex`), not new Phase 5
    # code - the core empties `active_invocations` on exit regardless of
    # whether the cascade itself runs, so the discard holds either way.
    # Recorded here because the plan states it as this phase's acceptance
    # criterion.
    # sabotage: flipped late_answer/3's liveness check (driver.ex) so a
    # cancelled invocation's late completion was answered instead of
    # discarded -> red, both assertions below failed. Verified red, reverted.
    test "a completion for the cancelled invocation is discarded and the parent is unchanged", %{
      store: store
    } do
      driver = driver(store, @parent_source, subchart_dispatch(@child_source))
      assert {:ok, _run, _ms} = Driver.create(driver, "run_1")

      assert {:ok, _run, machine_state} =
               Driver.send_event(driver, "run_1", Event.external("timeout"))

      assert leaves(machine_state) == ["abandoned"]

      {:ok, parent_machine} = Statifier.compile(@parent_source)
      assert {:ok, before} = Storage.load_run_position(store, "run_1", parent_machine)

      assert {:discarded, run} = Driver.done_invocation(driver, "run_1", "call", "late")
      assert run.status == :active

      assert {:ok, after_completion} = Storage.load_run_position(store, "run_1", parent_machine)
      assert after_completion == before
    end
  end

  # A dispatch fun that answers every `<invoke type="myapp:subchart">` with
  # `{:start_child, ...}`, the child's content swapped in for whatever the
  # element itself carried - exactly the shape `StatifierBlocks.Runtime.Subchart`
  # emits.
  defp subchart_dispatch(child_content) do
    fn
      "myapp:subchart", _params, %{invoke_id: invoke_id} = _context ->
        invoke = %Statifier.Effect.Invoke{
          invoke_id: invoke_id,
          type: "myapp:subchart",
          src: nil,
          params: nil,
          content: child_content,
          autoforward: nil,
          state_index: 0,
          invoke_index: 0,
          macrostep: 0,
          microstep: 0,
          round: 0
        }

        {:start_child, invoke, {:invoke, invoke}}
    end
  end

  # A dispatch fun shaped like a real subchart handler: it knows no chart
  # of its own, resolves the one this `<invoke>` names by `src` against
  # `charts`, and answers with the effect it was handed - `:content`
  # filled in, nothing else touched. Contrast `subchart_dispatch/1` above,
  # which synthesises an `%Invoke{}` because the seam gave it no other
  # option before sp-2yx.
  defp resolving_dispatch(charts) do
    fn "myapp:subchart", _params, %{invoke: %Statifier.Effect.Invoke{} = invoke} ->
      resolved = %{invoke | content: Map.fetch!(charts, invoke.src)}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  # A dispatch fun for the nesting case: the top-level "call" invocation
  # starts `@nesting_child_source` (which itself invokes "nested"), and
  # "nested" starts the plain `@child_source` leaf.
  defp nesting_dispatch do
    fn "myapp:subchart", _params, %{invoke_id: invoke_id} ->
      content = if invoke_id == "call", do: @nesting_child_source, else: @child_source

      invoke = %Statifier.Effect.Invoke{
        invoke_id: invoke_id,
        type: "myapp:subchart",
        src: nil,
        params: nil,
        content: content,
        autoforward: nil,
        state_index: 0,
        invoke_index: 0,
        macrostep: 0,
        microstep: 0,
        round: 0
      }

      {:start_child, invoke, {:invoke, invoke}}
    end
  end

  defp driver(store, source, dispatch, opts \\ []) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(
      store,
      machine,
      Keyword.merge(
        [dispatch: dispatch, invoke_types: InvokeTypes.new(types: ["myapp:subchart"])],
        opts
      )
    )
  end

  # A `chart_resolver:` that answers `parent_machine`'s own content hash and
  # refuses every other - the fixture for a driver that can find *its own*
  # parent's chart and nothing else.
  defp parent_resolver(parent_machine) do
    parent_hash = Machine.identity(parent_machine).content_hash

    fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
