defmodule StatifierPersistence.DriverInheritedMetadataTest do
  @moduledoc """
  ADR-0008's 2026-11-23 Amendment: a durable child copies, at its create,
  the host metadata keys the driver's `inherited_metadata_keys:` names
  from its parent.

  Every case that drives a child runs on both stores that declare
  `metadata`: the in-memory adapter and the Ecto adapter on Postgres
  (`EctoHosts.Default`). The Ecto adapter off Postgres declares no
  `metadata`, so a parent there holds no host key and a child has nothing
  to inherit (the Amendment's point 4); its linkage-columns cases are in
  `StatifierPersistence.Ecto.SqliteMigrationsTest`.

  The keys below are a library host's own: the branch a loan belongs to,
  and the patron who holds it.

  `async: false`, the reason `DriverSubchartEctoTest` gives: one
  sandbox-checked-out connection drives every `Storage.new/2` handle in a
  test.
  """

  use ExUnit.Case, async: false

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.EctoHosts
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.LoopingSubchart

  @type_name "myapp:subchart"
  @host_metadata %{"branch_id" => "branch_east", "patron_id" => "patron_7"}

  # A parent invoking "call", whose child invokes "nested", whose own child
  # is a plain leaf: a grandchild is created inside the child's create.
  @nesting_parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:subchart"/>
      </state>
  </scxml>
  """

  @nesting_child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="nested" type="myapp:subchart"/>
      </state>
  </scxml>
  """

  @leaf_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle"/>
  </scxml>
  """

  # A fan-out's parent: its invocation is answered later, by the children
  # `Driver.start_child_at/6` starts.
  @fan_out_parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling">
      <state id="calling">
          <invoke id="call" type="myapp:map"/>
      </state>
  </scxml>
  """

  for backend <- [:in_memory, :postgres] do
    describe "a child's create on the #{backend} store" do
      @describetag backend: backend

      setup %{backend: backend} do
        %{store: store(backend)}
      end

      # sabotage: in Driver's take_inherited/2, copied every host key (every
      # key but `Linkage.reserved_key/0`) -> red on both stores, the child
      # carried "patron_id". Verified red, reverted from a copy.
      test "a parent holding a named and an unnamed key: the child carries the named key only",
           %{store: store} do
        parent = "execution_loan_named"
        driver = LoopingSubchart.driver(store, @type_name, inherited_metadata_keys: ["branch_id"])
        first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

        assert {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)

        assert {:ok, record} = Storage.fetch_execution(store, first)

        assert Map.delete(record.metadata, Linkage.reserved_key()) == %{
                 "branch_id" => "branch_east"
               }

        assert {:ok, %Linkage{parent_execution_id: ^parent}} =
                 Linkage.from_metadata(record.metadata)
      end

      # sabotage: in Driver's take_inherited/2, wrote every named key, a
      # missing one as nil -> red on both stores, the child carried
      # "catalogue_id" => nil. Verified red, reverted from a copy.
      test "a named key the parent does not hold is not written", %{store: store} do
        parent = "execution_loan_missing"

        driver =
          LoopingSubchart.driver(store, @type_name,
            inherited_metadata_keys: ["branch_id", "catalogue_id"]
          )

        first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

        assert {:ok, _execution, _ms} =
                 Driver.create(driver, parent, metadata: %{"branch_id" => "branch_east"})

        assert {:ok, record} = Storage.fetch_execution(store, first)

        assert Map.delete(record.metadata, Linkage.reserved_key()) == %{
                 "branch_id" => "branch_east"
               }
      end

      # sabotage: in Driver's inherited_metadata/3, made a driver naming no
      # key copy every host key its create was given -> red on both stores,
      # the child carried both keys. Verified red, reverted from a copy.
      test "without the option a child carries its linkage and nothing else", %{store: store} do
        parent = "execution_loan_off"
        driver = LoopingSubchart.driver(store, @type_name)
        first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

        assert {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)

        assert {:ok, record} = Storage.fetch_execution(store, first)
        assert {:ok, linkage} = Linkage.from_metadata(record.metadata)
        assert record.metadata == Linkage.to_metadata(linkage)
      end

      # The second pass's child is created inside a step of the parent, so
      # it reads the parent's stored record rather than a create's
      # `metadata:`; a re-drive of that pass adopts it without writing it.
      # sabotage: in Driver's inherited_metadata/3, read the stored parent's
      # metadata as empty -> red on both stores, the second pass's child
      # carried no key. Verified red, reverted from a copy.
      test "a loop's later pass copies from the stored parent, and its adoption keeps the keys",
           %{store: store} do
        parent = "execution_loan_loop"
        driver = LoopingSubchart.driver(store, @type_name, inherited_metadata_keys: ["branch_id"])
        first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)

        assert {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)
        before_second_pass = LoopingSubchart.record(store, parent)

        assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))
        assert [{^first, :cancelled}, {second, :active}] = LoopingSubchart.children(store, parent)
        assert host_keys(store, second) == %{"branch_id" => "branch_east"}

        :ok = LoopingSubchart.lose_step(store, before_second_pass)
        assert {:ok, _execution, _ms} = Driver.send_event(driver, parent, Event.external("skip"))

        assert [{^first, :cancelled}, {^second, :active}] =
                 LoopingSubchart.children(store, parent)

        assert host_keys(store, second) == %{"branch_id" => "branch_east"}
      end

      # sabotage: in Driver's create_linked/5, created the child with the
      # driver's own keys option dropped from the child's driver (`%{driver |
      # machine: ..., inherited_metadata_keys: []}`) -> red on both stores,
      # the grandchild carried no key. Verified red, reverted from a copy.
      test "a grandchild copies the same keys from its parent, the child", %{store: store} do
        parent = "execution_loan_nested"

        driver =
          driver(store, @nesting_parent_source, nesting_dispatch(),
            inherited_metadata_keys: ["branch_id"]
          )

        child = Linkage.child_execution_id(parent, "call", 0)
        grandchild = Linkage.child_execution_id(child, "nested", 0)

        assert {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)

        assert host_keys(store, child) == %{"branch_id" => "branch_east"}
        assert host_keys(store, grandchild) == %{"branch_id" => "branch_east"}
      end

      # sabotage: in Driver's start_context/3, handed the fan-out an empty
      # map instead of the parent record's metadata -> red on both stores,
      # neither index carried the key. Verified red, reverted from a copy.
      test "each child of a fan-out copies from the parent record its door read", %{
        store: store
      } do
        parent = "execution_loan_fan_out"

        driver =
          Driver.new(store, compile(@fan_out_parent_source),
            dispatch: fn "myapp:map", _params, _context -> :pending end,
            invoke_types: InvokeTypes.new(types: ["myapp:map"]),
            inherited_metadata_keys: ["branch_id"]
          )

        assert {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)

        for index <- 0..1 do
          assert :ok = Driver.start_child_at(driver, parent, fan_out_effect(), index, 2)

          assert host_keys(store, Linkage.child_execution_id(parent, "call", index)) ==
                   %{"branch_id" => "branch_east"}
        end
      end

      # The Amendment's "What a host sees": with keys named, a child's
      # create on a step of the parent adds one read of the parent's
      # record; with none, it adds none.
      # sabotage: in Driver's inherited_metadata/3, made the empty-key clause
      # unreachable, so a driver naming no key read the parent's record too ->
      # red on both stores, the two counts were equal. Verified red,
      # reverted from a copy.
      test "a child created on a step reads the parent once when keys are named, never otherwise",
           %{store: store} do
        without = parent_reads(store, "execution_loan_reads_off", [])
        with_keys = parent_reads(store, "execution_loan_reads_on", ["branch_id"])

        assert with_keys == without + 1
      end
    end
  end

  describe "the option's refusals" do
    setup do
      %{store: store(:in_memory)}
    end

    # sabotage: in Driver's inherited_metadata_keys!/1, let atom and integer
    # keys through -> red, no raise for `[:branch_id]`. Verified red,
    # reverted from a copy.
    test "Driver.new/3 raises on a value that is not a list of strings, or names the reserved key",
         %{store: store} do
      for bad <- ["branch_id", [:branch_id], ["branch_id", 1], [Linkage.reserved_key()]] do
        assert_raise ArgumentError, fn ->
          LoopingSubchart.driver(store, @type_name, inherited_metadata_keys: bad)
        end
      end

      assert %Driver{inherited_metadata_keys: []} = LoopingSubchart.driver(store, @type_name)

      assert %Driver{inherited_metadata_keys: ["branch_id"]} =
               LoopingSubchart.driver(store, @type_name, inherited_metadata_keys: ["branch_id"])
    end

    # sabotage: in Driver's refuse_per_call_inheritance!/1, looked for a key
    # no call carries, so it never raised -> red, the create did not raise.
    # Verified red, reverted from a copy.
    test "a per-call list is refused on the four doors, before any read or write", %{
      store: store
    } do
      driver = LoopingSubchart.driver(store, @type_name)
      opts = [inherited_metadata_keys: ["branch_id"]]

      assert_raise ArgumentError, fn -> Driver.create(driver, "execution_loan_refused", opts) end

      assert {:error, :execution_not_found} =
               Storage.fetch_execution(store, "execution_loan_refused")

      parent = "execution_loan_doors"
      assert {:ok, _execution, _ms} = Driver.create(driver, parent)
      before = LoopingSubchart.record(store, parent)

      assert_raise ArgumentError, fn ->
        Driver.send_event(driver, parent, Event.external("skip"), opts)
      end

      assert_raise ArgumentError, fn ->
        Driver.done_invocation(driver, parent, LoopingSubchart.invoke_id(), nil, opts)
      end

      assert_raise ArgumentError, fn ->
        Driver.failed_invocation(driver, parent, LoopingSubchart.invoke_id(), [], opts)
      end

      assert LoopingSubchart.record(store, parent) == before
    end
  end

  defp store(:in_memory) do
    {:ok, store} = Storage.new(InMemory, [])
    store
  end

  defp store(:postgres) do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)
    :ok = Storage.Ecto.isolate(store.opts)
    store
  end

  defp host_keys(store, execution_id) do
    {:ok, record} = Storage.fetch_execution(store, execution_id)
    Map.delete(record.metadata, Linkage.reserved_key())
  end

  # The `:fetch_execution` adapter calls on the parent's own id while its
  # first pass's child ends and answers it, which steps the parent and
  # creates the second pass's child.
  defp parent_reads(store, parent, keys) do
    driver = LoopingSubchart.driver(store, @type_name, inherited_metadata_keys: keys)
    first = Linkage.child_execution_id(parent, LoopingSubchart.invoke_id(), 0)
    {:ok, _execution, _ms} = Driver.create(driver, parent, metadata: @host_metadata)

    test_pid = self()
    handler = "driver-inherited-metadata-#{parent}"

    :ok =
      :telemetry.attach(
        handler,
        [:statifier_persistence, :adapter, :call],
        &__MODULE__.handle_parent_read/4,
        {test_pid, handler, parent}
      )

    try do
      assert {:ok, %{status: :completed}, _ms} = LoopingSubchart.approve(driver, first)
    after
      :telemetry.detach(handler)
    end

    count_reads(handler, 0)
  end

  @doc false
  def handle_parent_read(_event, _measurements, metadata, {test_pid, handler, parent}) do
    if metadata.callback == :fetch_execution and metadata.execution_id == parent,
      do: send(test_pid, {handler, :parent_read})
  end

  defp count_reads(handler, count) do
    receive do
      {^handler, :parent_read} -> count_reads(handler, count + 1)
    after
      0 -> count
    end
  end

  defp compile(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  defp driver(store, source, dispatch, opts) do
    Driver.new(
      store,
      compile(source),
      Keyword.merge(
        [dispatch: dispatch, invoke_types: InvokeTypes.new(types: [@type_name])],
        opts
      )
    )
  end

  defp nesting_dispatch do
    fn @type_name, _params, %{invoke: %Invoke{} = invoke} ->
      content = if invoke.invoke_id == "call", do: @nesting_child_source, else: @leaf_source
      resolved = %{invoke | content: content}
      {:start_child, resolved, {:invoke, resolved}}
    end
  end

  defp fan_out_effect do
    %Invoke{
      invoke_id: "call",
      type: "myapp:map",
      src: nil,
      params: nil,
      content: @leaf_source,
      autoforward: nil,
      state_index: 0,
      invoke_index: 0,
      macrostep: 0,
      microstep: 0,
      round: 0
    }
  end
end
