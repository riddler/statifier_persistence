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

  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias StatifierPersistence.{Driver, Storage}
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

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    %{store: store}
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

  defp driver(store, source, dispatch) do
    {:ok, machine} = Statifier.compile(source)

    Driver.new(store, machine,
      dispatch: dispatch,
      invoke_types: InvokeTypes.new(types: ["myapp:subchart"])
    )
  end

  defp leaves(machine_state) do
    machine_state
    |> Statifier.MachineState.active_leaf_states()
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
