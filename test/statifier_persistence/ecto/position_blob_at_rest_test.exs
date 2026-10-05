defmodule StatifierPersistence.Ecto.PositionBlobAtRestTest do
  @moduledoc """
  What the Ecto adapter stores in `position_blob`, and what Ecto's query
  telemetry carries on the writes that bind it: the facts ADR-0004's
  2026-10-04 Note and the README's "Encrypting the blob columns" section
  record.

  Every `_ioprocessors` entry a registered send type answered at the
  create is part of the position, so a location a processor hands out -
  a capability carrying a token, here - is in the stored column in the
  clear on the default `:binary` blob type, and in the bound parameters
  of the create's `INSERT` and of a step's `UPDATE`. An encrypting
  `:blob_type` (the reversible stand-in here) keeps it out of the stored
  column. The column is read raw with `TestRepo.query!/2`, bypassing the
  schema, as `EctoBlobTypeTest` does.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.{Chart, Event, Position}
  alias Statifier.Send.Types, as: SendTypes
  alias StatifierPersistence.Ecto.Config
  alias StatifierPersistence.EctoHosts.{BlobTyped, Default}
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.TestRepo

  defmodule LoanNoticeProcessor do
    @moduledoc false
    # The one callback `Statifier.Send.Types.from_send_types/1` reads: the
    # value the engine writes into `_ioprocessors` for the type at create.
    @spec ioprocessors_entry(String.t()) :: map()
    def ioprocessors_entry(_type),
      do: %{"location" => "https://library.example/loan-notices?token=loan-capability-7f3a"}
  end

  @type_name "library:loan-notice"
  @location "https://library.example/loan-notices?token=loan-capability-7f3a"

  # A library loan: requested, checked out, returned.
  @loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="requested">
      <state id="requested">
          <transition event="checkout" target="on_loan"/>
      </state>
      <state id="on_loan">
          <transition event="return" target="returned"/>
      </state>
      <final id="returned"/>
  </scxml>
  """

  setup do
    :ok = Sandbox.checkout(TestRepo)
    {:ok, machine} = Statifier.compile(@loan)
    {:ok, chart_blob} = Chart.to_binary(machine)
    stamps = [send_types: SendTypes.from_send_types(%{@type_name => LoanNoticeProcessor})]
    %{machine: machine, chart_blob: chart_blob, stamps: stamps}
  end

  # A module capture rather than an anonymous fun, so :telemetry logs no
  # local-handler warning. The handler runs in the emitting process; the
  # sandbox makes that this test's own, so other tests' queries are dropped.
  @spec forward_query([atom()], map(), map(), %{pid: pid()}) :: :ok
  def forward_query(_name, _measurements, metadata, %{pid: pid}) do
    if self() == pid, do: send(pid, {:query, metadata.query, metadata.params})
    :ok
  end

  defp attach_query_handler do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:statifier_persistence, :test_repo, :query],
        &__MODULE__.forward_query/4,
        %{pid: self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp raw_position_blob(host, execution_id) do
    table = Config.table(host.__statifier_persistence__(:config), :executions)

    %{rows: [[raw]]} =
      TestRepo.query!(
        "SELECT position_blob FROM #{table} WHERE execution_id = $1",
        [execution_id]
      )

    raw
  end

  defp carries_location?(binary) when is_binary(binary),
    do: :binary.match(binary, @location) != :nomatch

  defp carries_location?(_other), do: false

  # The bound parameters of every query this process ran whose SQL starts
  # with `verb` and which bound a binary carrying the location.
  defp bound_location_params(verb) do
    for {:query, query, params} <- drain(),
        String.starts_with?(query, verb),
        Enum.any?(params, &carries_location?/1),
        do: params
  end

  defp drain do
    receive do
      {:query, _query, _params} = message -> [message | drain()]
    after
      0 -> []
    end
  end

  # sabotage: in Storage.Ecto's do_insert_execution/3, merged
  # `position_blob: nil` into the inserted row -> red on
  # `assert carries_location?(raw)`. Verified red, reverted.
  test "the stored position_blob carries an _ioprocessors entry's location in the clear",
       %{machine: machine, chart_blob: chart_blob, stamps: stamps} do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    :ok = Storage.save_chart(store, machine, chart_blob)

    {:ok, _execution, _state} =
      Executions.create(store, "loan-at-rest-1", machine, executor: &ok/2, initialize: stamps)

    raw = raw_position_blob(Default, "loan-at-rest-1")
    assert carries_location?(raw)

    assert {:ok, state} = Position.from_binary(raw, machine)
    assert %{@type_name => %{"location" => @location}} = state.datamodel["_ioprocessors"]
  end

  # sabotage: in Storage.Ecto.update_execution/2, bound `position_blob:
  # nil` in place of the record's blob -> red: no UPDATE bound a
  # parameter carrying the location. Verified red, reverted.
  test "the create's INSERT and a step's UPDATE bind the blob, cut but not absent in inspect",
       %{machine: machine, chart_blob: chart_blob, stamps: stamps} do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    :ok = Storage.save_chart(store, machine, chart_blob)
    attach_query_handler()

    {:ok, _execution, _state} =
      Executions.create(store, "loan-at-rest-2", machine, executor: &ok/2, initialize: stamps)

    assert [insert_params | _rest] = bound_location_params("INSERT")

    {:ok, _execution, _state} =
      Executions.step(store, "loan-at-rest-2", machine, Event.external("checkout"),
        executor: &ok/2
      )

    assert [update_params | _rest] = bound_location_params("UPDATE")
    assert carries_location?(raw_position_blob(Default, "loan-at-rest-2"))

    # Ecto's default log line renders the parameters with
    # `inspect(params, charlists: false)`: the blob is cut by the inspect
    # limit, so the location is not readable there, but the parameter the
    # telemetry event carries is the whole blob.
    refute inspect(insert_params, charlists: false) =~ @location
    refute inspect(update_params, charlists: false) =~ @location
  end

  # sabotage: in StatifierPersistence.Ecto.Config.blob_field_args/2, the
  # custom-type clause answered `[name, :binary]` -> red on the first
  # assertion: the INSERT bound the location in the clear. Verified red,
  # reverted.
  test "an encrypting :blob_type keeps the location out of the stored column and the bound blob",
       %{machine: machine, chart_blob: chart_blob, stamps: stamps} do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: BlobTyped)
    :ok = Storage.save_chart(store, machine, chart_blob)
    attach_query_handler()

    {:ok, _execution, _state} =
      Executions.create(store, "loan-at-rest-3", machine, executor: &ok/2, initialize: stamps)

    assert bound_location_params("INSERT") == []
    refute carries_location?(raw_position_blob(BlobTyped, "loan-at-rest-3"))

    {:ok, _execution, _state} =
      Executions.step(store, "loan-at-rest-3", machine, Event.external("checkout"),
        executor: &ok/2
      )

    # The step's UPDATE did bind a blob; it is the type's dumped bytes.
    updates =
      for {:query, "UPDATE" <> _rest = query, params} <- drain(),
          query =~ "position_blob",
          do: params

    assert updates != []
    refute Enum.any?(updates, fn params -> Enum.any?(params, &carries_location?/1) end)

    {:ok, record} = Storage.Ecto.fetch_execution(store_opts(BlobTyped), "loan-at-rest-3")
    assert {:ok, state} = Position.from_binary(record.position_blob, machine)
    assert %{@type_name => %{"location" => @location}} = state.datamodel["_ioprocessors"]
  end

  # The loan chart emits no effect a host acts on.
  defp ok(_effect, _context), do: :ok

  defp store_opts(host) do
    {:ok, opts} = Storage.Ecto.init(persistence: host)
    opts
  end
end
