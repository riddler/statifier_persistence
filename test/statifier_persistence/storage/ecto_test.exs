defmodule StatifierPersistence.Storage.EctoTest do
  @moduledoc """
  Adapter-level tests the conformance suite does not cover: `init/1`'s
  host refusal, the full status vocabulary round-tripping, row-count
  idempotence, and the same CRUD mechanisms against the schema-prefixed
  `Overridden` host (`workflows.wf_*`, `workflows.workflow_runs`) so
  none of them is proven only against the zero-config host.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.EctoHosts.{Default, Overridden}
  alias StatifierPersistence.Storage
  alias StatifierPersistence.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)

    {:ok, default} = Storage.Ecto.init(persistence: Default)
    {:ok, overridden} = Storage.Ecto.init(persistence: Overridden)

    %{default: default, overridden: overridden}
  end

  defp execution_record(execution_id, overrides \\ %{}) do
    Map.merge(
      %{
        execution_id: execution_id,
        status: :active,
        content_hash: "sha256:ecto-test-chart",
        identity_blob: <<1, 2, 3>>,
        position_blob: <<7, 8, 9>>,
        failure: nil,
        metadata: %{},
        outcome_blob: nil
      },
      overrides
    )
  end

  describe "init/1" do
    # sabotage: made persistence_host?/1 return true unconditionally ->
    # red, both refusals below returned {:ok, _} instead of the
    # {:adapter, {:not_a_persistence_host, _}} arm. Verified red,
    # reverted.
    test "refuses a module that never used StatifierPersistence.Ecto" do
      assert {:error, {:adapter, {:not_a_persistence_host, Enum}}} =
               Storage.Ecto.init(persistence: Enum)

      assert {:error, {:adapter, {:not_a_persistence_host, nil}}} =
               Storage.Ecto.init([])
    end
  end

  describe "execution status vocabulary" do
    # sabotage: crossed the @statuses mapping (completed -> "failed",
    # failed -> "failed2") -> the round trip alone stayed green (a
    # self-consistent swap is invisible to it), so this test also pins
    # the raw stored strings, which went red under the same mutation.
    # Verified red, reverted.
    test "all three statuses round-trip and store ADR-0004's strings", %{default: opts} do
      for {status, stored, execution_id} <- [
            {:active, "active", "execution-ecto-status-active"},
            {:completed, "completed", "execution-ecto-status-completed"},
            {:failed, "failed", "execution-ecto-status-failed"}
          ] do
        :ok =
          Storage.Ecto.insert_execution(opts, execution_record(execution_id, %{status: status}))

        assert {:ok, %{status: ^status}} = Storage.Ecto.fetch_execution(opts, execution_id)
        assert TestRepo.get_by(Default.Execution, execution_id: execution_id).status == stored
      end
    end
  end

  describe "row-count idempotence" do
    # sabotage: dropped the on_conflict/conflict_target options from
    # save_chart/2 -> red, the second save raised Ecto.ConstraintError
    # instead of returning :ok with one row. Verified red, reverted.
    test "a repeated save_chart/2 leaves exactly one row", %{default: opts} do
      chart_record = %{
        content_hash: "sha256:ecto-test-idempotent",
        identity_blob: <<1>>,
        chart_blob: <<2>>
      }

      :ok = Storage.Ecto.save_chart(opts, chart_record)
      :ok = Storage.Ecto.save_chart(opts, chart_record)

      assert TestRepo.aggregate(Default.Chart, :count) == 1
    end
  end

  describe "the schema-prefixed Overridden host" do
    # sabotage: hardcoded init/1's runs_table to "statifier_runs" -> red,
    # the duplicate insert below raised Ecto.ConstraintError (constraint
    # workflow_runs_run_id_index not declared under the wrong name)
    # instead of returning :execution_exists. Verified red, reverted.
    test "insert_execution/2 maps the renamed table's unique index to :execution_exists", %{
      overridden: opts
    } do
      :ok = Storage.Ecto.insert_execution(opts, execution_record("execution-ecto-overridden-dup"))

      assert {:error, :execution_exists} =
               Storage.Ecto.insert_execution(
                 opts,
                 execution_record("execution-ecto-overridden-dup", %{status: :failed})
               )
    end

    # sabotage: dropped the on_conflict/conflict_target options from
    # save_position/2 -> red, the second save below raised
    # Ecto.ConstraintError instead of overwriting. Verified red,
    # reverted (one mutation covering this test and the conformance
    # overwrite test together).
    test "chart, position, and execution CRUD work under the workflows schema", %{
      overridden: opts
    } do
      chart_record = %{
        content_hash: "sha256:ecto-overridden-chart",
        identity_blob: <<1>>,
        chart_blob: <<2>>
      }

      :ok = Storage.Ecto.save_chart(opts, chart_record)
      :ok = Storage.Ecto.save_chart(opts, chart_record)
      assert {:ok, ^chart_record} = Storage.Ecto.fetch_chart(opts, chart_record.content_hash)
      assert TestRepo.aggregate(Overridden.Chart, :count) == 1

      first = %{
        session_id: "sess_ecto_overridden",
        content_hash: "sha256:ecto-overridden-chart",
        identity_blob: <<1>>,
        position_blob: <<3>>
      }

      second = %{first | position_blob: <<4>>}
      :ok = Storage.Ecto.save_position(opts, first)
      :ok = Storage.Ecto.save_position(opts, second)
      assert {:ok, ^second} = Storage.Ecto.fetch_position(opts, "sess_ecto_overridden")

      inserted = execution_record("execution-ecto-overridden-crud")
      updated = %{inserted | status: :completed, position_blob: <<9, 9>>}
      :ok = Storage.Ecto.insert_execution(opts, inserted)
      :ok = Storage.Ecto.update_execution(opts, updated)

      assert {:ok, ^updated} =
               Storage.Ecto.fetch_execution(opts, "execution-ecto-overridden-crud")

      assert {:error, :execution_not_found} =
               Storage.Ecto.update_execution(
                 opts,
                 execution_record("execution-ecto-overridden-missing")
               )
    end
  end
end
