defmodule StatifierPersistence.NeedsMigrationTest do
  @moduledoc """
  The fifth execution status, `:needs_migration`, at the entry points
  (ADR-0014 decisions 2 to 4), over both shipped adapters.

  Nothing in this package parks an execution yet - the park is a
  migration's - so every case here sets the status through
  `StatifierPersistence.Storage.update_execution_status/4`, the same
  status-only write a park makes. The adapter half (the stored string,
  the counts, the pins) is pinned for every adapter by the conformance
  template.

  The fixture is a hold waiting for its patron to collect the copy.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.Event
  alias Statifier.Machine
  alias Statifier.MachineState
  alias StatifierPersistence.{Driver, EctoHosts, Execution, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage

  defmodule SpyStrategy do
    @moduledoc false
    # A pass-through serialization strategy whose config is the test pid,
    # so a case can see the strategy it named was the one that ran.
    @behaviour StatifierPersistence.Serialization

    @impl StatifierPersistence.Serialization
    def with_execution(test_pid, execution_id, fun) do
      send(test_pid, {:with_execution, execution_id})
      {:ok, fun.()}
    end
  end

  @hold """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_pickup">
      <state id="awaiting_pickup">
          <transition event="copy.collected" target="collected">
              <log label="collected"/>
          </transition>
          <transition event="pickup.expired" target="expired"/>
      </state>
      <final id="collected"/>
      <final id="expired"/>
  </scxml>
  """

  # Module captures rather than anonymous funs: :telemetry logs a
  # performance warning for a local handler.
  @spec forward([atom()], map(), map(), %{pid: pid()}) :: :ok
  def forward(name, _measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, name, metadata})
    :ok
  end

  setup %{adapter: adapter} do
    store = store(adapter)
    {:ok, machine} = Statifier.compile(@hold)
    test_pid = self()

    executor = fn effect, _context ->
      send(test_pid, {:executed, effect})
      :ok
    end

    %{store: store, machine: machine, executor: executor}
  end

  defp store(:in_memory) do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    store
  end

  defp store(:ecto) do
    {:ok, store} =
      Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)

    :ok = Storage.Ecto.isolate(store.opts)
    store
  end

  # A hold created and then parked the way a migration parks one: its
  # status alone written, every other stored field carried forward.
  defp parked_hold(store, machine, execution_id) do
    {:ok, _execution, _ms} = Executions.create(store, execution_id, machine, executor: &quiet/2)

    :ok = Storage.update_execution_status(store, execution_id, :needs_migration)
    {:ok, record} = Storage.fetch_execution(store, execution_id)
    record
  end

  defp quiet(_effect, _context), do: :ok

  defp attach(test_pid, event) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, event, &__MODULE__.forward/4, %{pid: test_pid})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "a delivery to a parked execution" do
    # sabotage: drop step_tail/7's :needs_migration refusal arm -> red over
    # both adapters: the hold was loaded and stepped to `collected`.
    # Verified red, reverted from a copy.
    test "is refused whole: nothing appended, executed or written", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      before = parked_hold(store, machine, "hold-1")
      {:ok, inputs_before} = inputs(store, "hold-1")

      assert {:error, {:needs_migration, %Execution{execution_id: "hold-1"} = execution}} =
               Executions.step(store, "hold-1", machine, Event.external("copy.collected"),
                 executor: executor
               )

      assert execution.status == :needs_migration
      assert execution.content_hash == before.content_hash
      refute_received {:executed, _effect}
      assert {:ok, ^before} = Storage.fetch_execution(store, "hold-1")
      assert inputs(store, "hold-1") == {:ok, inputs_before}
    end

    # sabotage: drop step_tail/7's :needs_migration refusal arm -> red over
    # both adapters: the Driver door stepped the parked hold. Verified red,
    # reverted from a copy.
    test "through a Driver door answers the same refusal", %{store: store, machine: machine} do
      parked_hold(store, machine, "hold-driven")

      driver = Driver.new(store, machine, dispatch: fn _type, _params, _context -> :ok end)

      assert {:error, {:needs_migration, %Execution{status: :needs_migration}}} =
               Driver.send_event(driver, "hold-driven", Event.external("copy.collected"))

      assert {:ok, %{status: :needs_migration}} = Storage.fetch_execution(store, "hold-driven")
    end

    # sabotage: drop stop_shape/1's :needs_migration clause -> red over
    # both adapters: the stop carried the whole error term as its reason.
    # Verified red, reverted from a copy.
    test "closes its step span as an error with the bare reason and no status", %{
      store: store,
      machine: machine,
      executor: executor,
      adapter: adapter
    } do
      execution_id = "hold-span-#{adapter}"
      parked_hold(store, machine, execution_id)
      attach(self(), [:statifier_persistence, :execution, :step, :stop])

      {:error, {:needs_migration, _execution}} =
        Executions.step(store, execution_id, machine, Event.external("copy.collected"),
          executor: executor
        )

      assert_receive {:telemetry, _name, %{execution_id: ^execution_id} = metadata}
      assert metadata.outcome == :error
      assert metadata.status == nil
      assert metadata.reason == :needs_migration
      assert is_binary(metadata.content_hash)
    end
  end

  describe "host decisions about a parked execution" do
    # sabotage: add :needs_migration to fail_tail/3's terminal list -> red
    # over both adapters: the parked hold was discarded instead of failed.
    # Verified red, reverted from a copy.
    test "fail/4 proceeds as it does on an :active one", %{store: store, machine: machine} do
      parked_hold(store, machine, "hold-failed")

      assert {:ok, %Execution{status: :failed, failure: "branch: closed"}} =
               Executions.fail(store, "hold-failed", "branch: closed")

      assert {:ok, %{status: :failed}} = Storage.fetch_execution(store, "hold-failed")
    end

    # sabotage: add :needs_migration to cancel_tail/2's terminal list ->
    # red over both adapters: the parked hold was discarded, not
    # cancelled. Verified red, reverted from a copy.
    test "cancel/3 proceeds as it does on an :active one", %{store: store, machine: machine} do
      parked_hold(store, machine, "hold-cancelled")

      assert {:ok, %Execution{status: :cancelled}} = Executions.cancel(store, "hold-cancelled")
      assert {:ok, %{status: :cancelled}} = Storage.fetch_execution(store, "hold-cancelled")
    end

    # sabotage: add :needs_migration to cancel_tail/2's terminal list ->
    # red over both adapters: the cascade left the parked child as it was
    # and counted nothing. Verified red, reverted from a copy.
    test "a cascading cancel reaches a parked child", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      {:ok, _execution, _ms} =
        Executions.create(store, "loan-1", machine, executor: executor)

      child_id = Linkage.child_execution_id("loan-1", "hold", 0)
      linkage = Linkage.new("loan-1", "hold", 0, Machine.identity(machine).content_hash)

      :ok =
        Storage.insert_execution(
          store,
          child_id,
          MachineState.new(machine, session_id: "sess-hold-child"),
          :needs_migration,
          metadata: Linkage.to_metadata(linkage)
        )

      assert {:ok, 1} = Executions.cascade_cancel(store, Linkage.parent_match("loan-1"))
      assert {:ok, %{status: :cancelled}} = Storage.fetch_execution(store, child_id)
    end
  end

  describe "unpark/3" do
    # sabotage: unpark_tail/2's parked arm answers {:ok, _} without the
    # status write -> red over both adapters: the stored row stayed
    # :needs_migration. Verified red, reverted from a copy.
    test "puts a parked execution back to :active where it was, and it steps there", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      before = parked_hold(store, machine, "hold-unparked")

      assert {:ok, %Execution{status: :active, content_hash: content_hash}} =
               Executions.unpark(store, "hold-unparked")

      assert content_hash == before.content_hash
      assert {:ok, after_unpark} = Storage.fetch_execution(store, "hold-unparked")
      assert after_unpark == %{before | status: :active}

      assert {:ok, %Execution{status: :completed}, %MachineState{status: :done}} =
               Executions.step(store, "hold-unparked", machine, Event.external("copy.collected"),
                 executor: executor
               )

      assert_received {:executed, {:log, %{label: "collected"}}}
    end

    # sabotage: unpark_tail/2's :active arm writes :active again -> red
    # over both adapters: an update_execution call was reported. Verified
    # red, reverted from a copy.
    test "on an :active execution answers {:ok, _} and writes nothing", %{
      store: store,
      machine: machine,
      executor: executor,
      adapter: adapter
    } do
      execution_id = "hold-active-#{adapter}"

      {:ok, _execution, _ms} =
        Executions.create(store, execution_id, machine, executor: executor)

      attach(self(), [:statifier_persistence, :adapter, :call])

      assert {:ok, %Execution{status: :active}} = Executions.unpark(store, execution_id)

      callbacks = collect_callbacks(execution_id)
      assert :fetch_execution in callbacks
      refute Enum.any?(callbacks, &(&1 in [:update_execution, :insert_execution]))
    end

    # sabotage: unpark_tail/2's write arm widened to every non-:active
    # status -> red over both adapters: the cancelled hold was written
    # back to :active. Verified red, reverted from a copy.
    test "on a terminal execution is discarded and writes nothing", %{
      store: store,
      machine: machine
    } do
      parked_hold(store, machine, "hold-ended")
      {:ok, _cancelled} = Executions.cancel(store, "hold-ended")

      assert {:discarded, %Execution{status: :cancelled}} =
               Executions.unpark(store, "hold-ended")

      assert {:ok, %{status: :cancelled}} = Storage.fetch_execution(store, "hold-ended")
    end

    # sabotage: unpark_tail/2's fetch error arm rewrites the reason -> red
    # over both adapters. Verified red, reverted from a copy.
    test "on a missing execution answers :execution_not_found", %{store: store} do
      assert {:error, :execution_not_found} = Executions.unpark(store, "hold-absent")
    end

    # sabotage: unpark/3 ignores `serialization:` and always takes the
    # adapter lock -> red over both adapters: the named strategy never
    # ran. Verified red, reverted from a copy.
    test "runs inside the serialization strategy it is given", %{
      store: store,
      machine: machine
    } do
      parked_hold(store, machine, "hold-serialized")

      assert {:ok, %Execution{status: :active}} =
               Executions.unpark(store, "hold-serialized", serialization: {SpyStrategy, self()})

      assert_received {:with_execution, "hold-serialized"}
    end
  end

  describe "executions_on/2" do
    # sabotage: unpark_tail/2's parked arm skips its status write -> red
    # over both adapters: the count still read needs_migration: 1 after
    # the unpark. Verified red, reverted from a copy. (The key itself is
    # pinned by the conformance suite's parked-count case.)
    test "answers the parked executions under their own key", %{
      store: store,
      machine: machine,
      executor: executor
    } do
      parked_hold(store, machine, "hold-counted")

      {:ok, _execution, _ms} =
        Executions.create(store, "hold-waiting", machine, executor: executor)

      assert {:ok, counts} =
               Executions.executions_on(store, Machine.identity(machine).content_hash)

      assert counts == %{
               active: 1,
               needs_migration: 1,
               completed: 0,
               failed: 0,
               cancelled: 0,
               children: 0
             }

      {:ok, _execution} = Executions.unpark(store, "hold-counted")

      assert {:ok, %{active: 2, needs_migration: 0}} =
               Executions.executions_on(store, Machine.identity(machine).content_hash)
    end
  end

  defp inputs(store, execution_id) do
    case Executions.inputs(store, execution_id) do
      :not_supported -> {:ok, :not_supported}
      {:ok, entries} -> {:ok, entries}
    end
  end

  # The handler is global and this module is async, so every concurrent
  # test's adapter calls arrive here too: only the calls made for
  # `execution_id` are collected, and the rest are left unread.
  defp collect_callbacks(execution_id, acc \\ []) do
    receive do
      {:telemetry, [:statifier_persistence, :adapter, :call],
       %{callback: callback, execution_id: ^execution_id}} ->
        collect_callbacks(execution_id, [callback | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
