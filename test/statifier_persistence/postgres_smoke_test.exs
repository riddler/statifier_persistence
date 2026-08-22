defmodule StatifierPersistence.PostgresSmokeTest do
  @moduledoc """
  Connectivity smoke test for ADR-0005's Postgres harness.

  This asserts infrastructure (a reachable database), not `lib/` behavior,
  so it carries no sabotage note per the repo's convention - there is no
  application code here to break and revert.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.TestRepo

  setup do
    case Sandbox.checkout(TestRepo) do
      :ok ->
        :ok

      {:error, reason} ->
        flunk("""
        Could not check out a connection to the Postgres test database \
        (#{inspect(reason)}).

        Start it with `docker compose up -d db` (see README.md, "Running \
        the tests"), or point PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE \
        at an existing server.
        """)
    end
  end

  test "the repo answers SELECT 1" do
    assert {:ok, %{rows: [[1]]}} = TestRepo.query("SELECT 1")
  end
end
