defmodule StatifierPersistence.Test.LoopingSubchart do
  @moduledoc """
  The fixture for a durable subchart inside a loop (ADR-0008's 2026-11-22
  Amendment): a parent that renews two loans one at a time, re-entering
  the same invoking state for each, under one fixed invoke id - the shape
  a compiled loop over a subchart step takes, where the invoke id is
  written once at compile time and every pass reuses it.

  Shared by the three stores the Amendment is proved on: the in-memory
  adapter, the Ecto adapter on Postgres, and the Ecto adapter on SQLite
  with the linkage columns on. Each test module keeps its own assertions;
  this module holds only the charts and the drive.
  """

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine
  alias Statifier.MachineState
  alias StatifierPersistence.{Driver, Storage}
  alias StatifierPersistence.Execution.Linkage

  @invoke_id "renewal"

  # One loan renewed per pass. The first answer loops back into
  # "renewing", which exits and re-enters it, so the second pass starts
  # the same `<invoke id="renewal">` again; the second answer leaves.
  @parent_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="renewing">
      <datamodel>
          <data id="renewed" expr="0"/>
      </datamodel>
      <state id="renewing">
          <invoke id="renewal" type="TYPE"/>
          <transition event="done.invoke.renewal" cond="renewed == 1" target="renewed_all">
              <assign location="renewed" expr="renewed + 1"/>
          </transition>
          <transition event="done.invoke.renewal" target="renewing">
              <assign location="renewed" expr="renewed + 1"/>
          </transition>
          <transition event="skip" target="renewing"/>
          <transition event="error.communication.invoke.renewal" target="refused"/>
      </state>
      <state id="renewed_all"/>
      <state id="refused"/>
  </scxml>
  """

  # One loan's renewal: it ends when the library approves it.
  @child_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_approval">
      <state id="awaiting_approval">
          <transition event="approve" target="renewed"/>
      </state>
      <final id="renewed"/>
  </scxml>
  """

  @doc "The invoke id every pass of the loop reuses."
  @spec invoke_id() :: String.t()
  def invoke_id, do: @invoke_id

  @doc "The parent chart, its `<invoke>` typed `type`."
  @spec parent_source(String.t()) :: String.t()
  def parent_source(type), do: String.replace(@parent_source, "TYPE", type)

  @doc """
  A driver over the parent chart whose dispatch answers every
  `<invoke type={type}>` with the child chart, and whose `chart_resolver:`
  finds the parent's chart, so a child that ends answers its parent.
  `opts` are merged into `Driver.new/3`'s.
  """
  @spec driver(Storage.t(), String.t(), keyword()) :: Driver.t()
  def driver(store, type, opts \\ []) do
    {:ok, parent_machine} = Statifier.compile(parent_source(type))
    parent_hash = Machine.identity(parent_machine).content_hash

    dispatch = fn ^type, _params, %{invoke: %Invoke{} = invoke} ->
      resolved = %{invoke | content: @child_source}
      {:start_child, resolved, {:invoke, resolved}}
    end

    resolver = fn
      ^parent_hash -> {:ok, parent_machine}
      _other_hash -> :error
    end

    Driver.new(
      store,
      parent_machine,
      Keyword.merge(
        [
          dispatch: dispatch,
          invoke_types: InvokeTypes.new(types: [type]),
          chart_resolver: resolver
        ],
        opts
      )
    )
  end

  @doc "The same driver over the child's chart, as a node answering a child holds."
  @spec child_driver(Driver.t()) :: Driver.t()
  def child_driver(driver) do
    {:ok, child_machine} = Statifier.compile(@child_source)
    %{driver | machine: child_machine}
  end

  @doc "Approves one renewal: the child ends and answers its parent."
  @spec approve(Driver.t(), String.t()) :: term()
  def approve(driver, child_execution_id) do
    Driver.send_event(child_driver(driver), child_execution_id, Event.external("approve"))
  end

  @doc """
  The parent's children as `{execution_id, status}`, the first pass's
  first: the first pass's child is the one under
  `Linkage.child_execution_id/3`, and every later pass's id extends it.
  """
  @spec children(Storage.t(), String.t()) :: [{String.t(), atom()}]
  def children(store, parent) do
    {:ok, records} = Storage.list_executions_by_metadata(store, Linkage.parent_match(parent))

    records
    |> Enum.map(&{&1.execution_id, &1.status})
    |> Enum.sort_by(fn {execution_id, _status} -> {String.length(execution_id), execution_id} end)
  end

  @doc "The parent's stored record, as the adapter holds it."
  @spec record(Storage.t(), String.t()) :: map()
  def record(store, execution_id) do
    {:ok, record} = Storage.fetch_execution(store, execution_id)
    record
  end

  @doc """
  Puts `record` back as the stored record: the parent's persist of the step
  that followed it never happened, the crash window an at-least-once
  re-drive answers.
  """
  @spec lose_step(Storage.t(), map()) :: :ok
  def lose_step(%Storage{adapter: adapter, opts: opts}, record) do
    :ok = adapter.update_execution(opts, record)
  end

  @doc "The parent's active leaf state ids, reloaded from the store."
  @spec leaves(Storage.t(), String.t(), String.t()) :: [String.t()]
  def leaves(store, type, parent) do
    {:ok, machine} = Statifier.compile(parent_source(type))
    {:ok, machine_state} = Storage.load_execution_position(store, parent, machine)

    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine_state.machine, &1))
    |> Enum.sort()
  end
end
