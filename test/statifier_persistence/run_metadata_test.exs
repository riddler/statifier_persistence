defmodule StatifierPersistence.RunMetadataTest do
  @moduledoc """
  ADR-0006's optional opaque run metadata at the facade and lifecycle
  levels: the option's shape, the refusal at open, and the write-once
  rule.

  The adapter-level round trip and refusal are the conformance suite's
  (`StorageConformance`, run here over `InMemory` and over
  `NoLockAdapter`, which declares no support). What this module adds is
  what the suite cannot say generically: that `Runs.create/4` threads the
  option through, that a refused create executes no effect, and that a
  malformed option raises rather than joining the error vocabulary.
  """

  use ExUnit.Case, async: true

  defmodule PassThrough do
    @moduledoc false
    # A pass-through StatifierPersistence.Serialization strategy, so the
    # tests below can drive an adapter that exports no lock_run/3 (the
    # default AdapterLock strategy would refuse it before any metadata
    # question was reached).
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_run(_config, _run_id, fun), do: {:ok, fun.()}
  end

  alias Statifier.Event
  alias Statifier.MachineState
  alias StatifierPersistence.{Runs, Storage}
  alias StatifierPersistence.Storage.InMemory
  alias StatifierPersistence.Test.NoLockAdapter
  alias StatifierPersistence.Testing.Charts

  # A chart whose entry action emits an observational effect, so a create
  # refused at open can be told apart from one that ran and rolled back:
  # a refused create must leave the executor with nothing recorded.
  @logging_chart_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <log label="entered"/>
          </onentry>
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(InMemory, [])
    {_source, machine} = Charts.chart_a()
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    %{store: store, machine: machine, executor: executor(recorder), recorder: recorder}
  end

  # A per-test recording executor, as an arity-2 fun rather than the
  # module-named `RecordingExecutor`: that one registers under a global
  # name, which collides across async modules.
  defp executor(recorder) do
    fn effect, context ->
      Agent.update(recorder, &[{effect, context} | &1])
      :ok
    end
  end

  defp recorded(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  defp logging_machine do
    {:ok, machine} = Statifier.compile(@logging_chart_source)
    machine
  end

  describe "Runs.create/4 with metadata" do
    # sabotage: in Runs.create/4, drop the {:metadata, metadata} entry from
    # write_run/6's insert opts (pass `opts` unchanged) -> red, the fetched
    # record's metadata came back %{} instead of the two pairs. Verified
    # red, reverted.
    test "threads the map through to the stored run record", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      metadata = %{"tenant_id" => "acct_01H8X", "processor_account_id" => "pacct_4471"}

      assert {:ok, _run, _ms} =
               Runs.create(store, "run-md-1", machine,
                 executor: executor,
                 metadata: metadata
               )

      assert {:ok, record} = Storage.fetch_run(store, "run-md-1")
      assert record.metadata == metadata
    end

    # sabotage: in Runs.metadata/1, change the default from %{} to a
    # non-empty map -> red, the fetched record carried the invented pair
    # instead of %{}. (Making InMemory.insert_run/2 default an absent
    # metadata key to nil does NOT go red here, and that is worth knowing:
    # the facade always builds the field, so the adapter's own default is
    # defence for a direct adapter caller, not the path this test walks.)
    # Verified red, reverted.
    test "defaults to the empty map when no option is given", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      assert {:ok, _run, _ms} =
               Runs.create(store, "run-md-2", machine, executor: executor)

      assert {:ok, record} = Storage.fetch_run(store, "run-md-2")
      assert record.metadata == %{}
    end

    # sabotage: in Runs.create/4, delete the Storage.check_metadata/2
    # guard entirely and rely on insert_run/5's own check -> red, the
    # persist tail executed the entry <log> through the executor on its way
    # to the refusal, so calls() was no longer empty. This is the assertion
    # that pins "at open" to "before any effect"; merely moving the guard
    # to after initialize/2 does not go red, because initialize/2 computes
    # effects without executing them. Verified red, reverted.
    test "refuses at open on an adapter with no metadata support, executing no effect", %{
      executor: executor,
      recorder: recorder
    } do
      {:ok, store} = Storage.new(NoLockAdapter, [])
      machine = logging_machine()

      assert {:error, :metadata_unsupported} =
               Runs.create(store, "run-md-3", machine,
                 executor: executor,
                 serialization: {PassThrough, nil},
                 metadata: %{"tenant_id" => "acct_01H8X"}
               )

      assert recorded(recorder) == []
      assert {:error, :run_not_found} = Storage.fetch_run(store, "run-md-3")
    end

    # sabotage: in Storage's check_metadata_supported/2, delete the
    # map_size(metadata) == 0 clause -> red, this create returned
    # {:error, :metadata_unsupported} instead of {:ok, _, _}. Verified
    # red, reverted.
    test "an empty or absent map is never refused, even with no adapter support", %{
      executor: executor
    } do
      {:ok, store} = Storage.new(NoLockAdapter, [])
      {_source, machine} = Charts.chart_a()

      assert {:ok, _run, _ms} =
               Runs.create(store, "run-md-4", machine,
                 executor: executor,
                 serialization: {PassThrough, nil},
                 metadata: %{}
               )

      assert {:ok, _run, _ms} =
               Runs.create(store, "run-md-5", machine,
                 executor: executor,
                 serialization: {PassThrough, nil}
               )
    end

    # sabotage: in Storage's metadata_opt!/1, return the option unchanged
    # instead of validating it -> red, no ArgumentError was raised and the
    # create returned {:ok, _, _} with an atom-keyed map stored. Verified
    # red, reverted.
    test "a map with non-string keys raises ArgumentError", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      assert_raise ArgumentError, ~r/string keys/, fn ->
        Runs.create(store, "run-md-6", machine,
          executor: executor,
          metadata: %{tenant_id: "acct_01H8X"}
        )
      end
    end

    # sabotage: same mutation as above -> red for the same reason with a
    # non-map option. Verified red, reverted.
    test "a non-map option raises ArgumentError", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      assert_raise ArgumentError, ~r/must be a map/, fn ->
        Runs.create(store, "run-md-7", machine,
          executor: executor,
          metadata: [{"tenant_id", "acct_01H8X"}]
        )
      end
    end
  end

  describe "write-once" do
    # sabotage: in InMemory.update_run/2, put the given record's metadata
    # instead of the stored map (drop the Map.put restoring it) -> red,
    # the fetch after the step saw %{} where the created map should be.
    # Verified red, reverted.
    test "a step does not disturb the stored map", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      metadata = %{"tenant_id" => "acct_01H8X"}

      {:ok, _run, _ms} =
        Runs.create(store, "run-md-8", machine,
          executor: executor,
          metadata: metadata
        )

      assert {:ok, _run, %MachineState{}} =
               Runs.step(store, "run-md-8", machine, Event.external("go"), executor: executor)

      assert {:ok, record} = Storage.fetch_run(store, "run-md-8")
      assert record.metadata == metadata
    end

    # sabotage: this path is guarded twice over and only a double mutation
    # reaches it, which is itself the finding: Storage.update_run_status/4
    # updates the *fetched* record (so metadata survives whatever the
    # adapter does), and InMemory.update_run/2 carries the stored map
    # forward (so metadata survives whatever the facade passes). Setting
    # metadata: %{} in update_run_status/4's updated record alone is green,
    # and writing the given record's metadata in InMemory.update_run/2
    # alone is green; both together -> red, the fetch after the
    # abandonment saw %{}. Verified red on the pair, reverted.
    test "an abandonment does not disturb the stored map", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      metadata = %{"tenant_id" => "acct_01H8X"}

      {:ok, _run, _ms} =
        Runs.create(store, "run-md-9", machine,
          executor: executor,
          metadata: metadata
        )

      assert {:ok, _run} = Runs.fail(store, "run-md-9", "abandoned: operator request")

      assert {:ok, record} = Storage.fetch_run(store, "run-md-9")
      assert record.status == :failed
      assert record.metadata == metadata
    end
  end

  describe "Storage.metadata_supported?/1" do
    # sabotage: in Storage.metadata_supported?/1, drop the
    # function_exported?/3 conjunct so the call is attempted regardless ->
    # red, the NoLockAdapter assertion raised UndefinedFunctionError
    # instead of returning false. Verified red, reverted.
    test "is true for InMemory and false for an adapter that does not export it", %{
      store: store
    } do
      assert Storage.metadata_supported?(store)

      {:ok, no_metadata} = Storage.new(NoLockAdapter, [])
      refute Storage.metadata_supported?(no_metadata)
    end
  end
end
