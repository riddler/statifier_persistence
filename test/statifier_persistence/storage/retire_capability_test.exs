defmodule StatifierPersistence.Storage.RetireCapabilityTest do
  @moduledoc """
  Which arm `StatifierPersistence.Storage.retire_chart/3` answers at
  open, named per adapter rather than read off the adapter's own
  predicates.

  The conformance case "a retirement either runs or is declined at open"
  branches on `content_hash_query_supported?/1` and
  `chart_retirement_supported?/1`, the same two predicates the facade
  branches on, so it proves every arm is reachable and cannot notice a
  predicate that answers wrongly: an adapter whose retirement predicate
  says `false` for a store that can carry a tombstone passes it on the
  declining arm. Here each adapter this package ships or tests against
  is held to the arm it is known to give, and a hash none of them holds
  keeps a supporting store's answer to `:chart_not_found`.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.EctoHosts.Default
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Test.{InputLogAdapter, NoLockAdapter}
  alias StatifierPersistence.TestRepo

  @never_stored "sha256:loan-chart-never-stored"

  # sabotage: in StatifierPersistence.Storage.InMemory, answer false
  # from supports_chart_retirement?/1 -> red here, the retirement was
  # declined with :chart_retirement_unsupported where this asserts the
  # miss; the in-memory conformance suite stayed green on its declining
  # arm ("54 tests, 1 failure", this case alone). Reverted from a copy.
  test "the in-memory adapter supports retirement, so an unknown hash is a miss" do
    {:ok, store} = Storage.new(Storage.InMemory, [])

    assert {:error, :chart_not_found} = retire(store)
  end

  # sabotage: in StatifierPersistence.Storage.Ecto's
  # tombstone_columns_ready?/3, compare the qualifying count against 5
  # instead of 4 -> red here, a V07-migrated Postgres store was declined
  # with :chart_retirement_unsupported; the Ecto conformance suite stayed
  # green on its declining arm ("55 tests, 0 failures"). Reverted from a
  # copy, and the file touched before the green re-run.
  test "the Ecto adapter over a V07-migrated Postgres store supports retirement" do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: Default)
    :ok = Sandbox.checkout(TestRepo)

    assert {:error, :chart_not_found} = retire(store)
  end

  # sabotage: in StatifierPersistence.Storage.retire_chart/3, drop the
  # chart_retirement_supported?/1 cond clause -> red here, the adapter
  # was called and raised instead of declining. Reverted from a copy.
  test "an adapter that answers the drained query but carries no tombstone declines it" do
    {:ok, store} = Storage.new(InputLogAdapter, [])

    assert {:error, :chart_retirement_unsupported} = retire(store)
  end

  # sabotage: in StatifierPersistence.Storage.retire_chart/3, put the
  # chart_retirement_supported?/1 cond clause above the drained-query
  # one -> red here, the answer was :chart_retirement_unsupported.
  # Reverted from a copy.
  test "an adapter that cannot answer the drained query declines on that first" do
    {:ok, store} = Storage.new(NoLockAdapter, [])

    assert {:error, :content_hash_query_unsupported} = retire(store)
  end

  defp retire(store) do
    Storage.retire_chart(store, @never_stored, retired_by: "branch-librarian")
  end
end
