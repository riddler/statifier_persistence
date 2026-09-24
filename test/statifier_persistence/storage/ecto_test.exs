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
        outcome_blob: nil,
        ended_at: nil
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
    # The arms are read off `t:StatifierPersistence.Storage.Adapter.execution_status/0`
    # itself rather than listed here, so an arm added to the type without
    # a stored string fails this test instead of being left out of it
    # (ADR-0014 decision 5). Each arm is stored as its own name.
    #
    # sabotage: drop the `needs_migration: "needs_migration"` entry from the
    # Ecto adapter's @statuses -> red, the parked insert raised
    # FunctionClauseError in encode_status/1. Verified red, reverted from a
    # copy.
    test "every arm of the status type round-trips and stores its own name", %{default: opts} do
      statuses = execution_status_arms()

      assert :needs_migration in statuses
      assert length(statuses) == 5

      for status <- statuses do
        execution_id = "execution-ecto-status-#{status}"

        :ok =
          Storage.Ecto.insert_execution(opts, execution_record(execution_id, %{status: status}))

        assert {:ok, %{status: ^status}} = Storage.Ecto.fetch_execution(opts, execution_id)

        assert TestRepo.get_by(Default.Execution, execution_id: execution_id).status ==
                 Atom.to_string(status)
      end
    end
  end

  # The atoms of the union `t:execution_status/0` is declared as, read
  # from the compiled module's typespecs.
  defp execution_status_arms do
    {:ok, types} = Code.Typespec.fetch_types(StatifierPersistence.Storage.Adapter)

    {:type, {:execution_status, {:type, _line, :union, arms}, []}} =
      Enum.find(types, &match?({:type, {:execution_status, _ast, []}}, &1))

    Enum.map(arms, fn {:atom, _line, atom} -> atom end)
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
    # sabotage: hardcoded init/1's executions_table to "statifier_executions" -> red,
    # the duplicate insert below raised Ecto.ConstraintError (constraint
    # workflow_runs_execution_id_index not declared under the wrong name)
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

  describe "the narrow tombstone read" do
    # The conformance suite proves what fetch_retired_info/2 answers; the
    # bytes staying behind can only be seen in the statement itself, so
    # it is read here off the repo's own query telemetry. The fetch_chart/2
    # half is the control: the same observation does see the blobs when a
    # read selects them.
    #
    # sabotage: made fetch_retired_info/2 answer through
    # `repo(opts).get_by(chart_schema(opts), content_hash: content_hash)`
    # and read retired_at and retired_by off the row -> red, the statement
    # selected chart_blob and identity_blob. Verified red, reverted from a
    # copy.
    test "reads retired_at and retired_by without selecting either chart blob", %{
      default: opts
    } do
      :ok =
        Storage.Ecto.save_chart(opts, %{
          content_hash: "sha256:ecto-narrow-read",
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        })

      narrow =
        statements(fn -> Storage.Ecto.fetch_retired_info(opts, "sha256:ecto-narrow-read") end)

      full = statements(fn -> Storage.Ecto.fetch_chart(opts, "sha256:ecto-narrow-read") end)

      assert [narrow_sql] = narrow
      assert narrow_sql =~ "retired_at"
      assert narrow_sql =~ "retired_by"
      refute narrow_sql =~ "chart_blob"
      refute narrow_sql =~ "identity_blob"

      assert [full_sql] = full
      assert full_sql =~ "chart_blob"
    end
  end

  # Every statement the repo runs on this process while `fun` does.
  defp statements(fun) do
    test_pid = self()
    handler_id = {__MODULE__, :statements, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:statifier_persistence, :test_repo, :query],
        &__MODULE__.forward_statement/4,
        %{pid: test_pid}
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_statements([])
  end

  def forward_statement(_event, _measurements, metadata, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, metadata.query})
  end

  defp collect_statements(acc) do
    receive do
      {:statement, sql} -> collect_statements([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
