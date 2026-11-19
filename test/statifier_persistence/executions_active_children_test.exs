defmodule StatifierPersistence.ExecutionsActiveChildrenTest do
  @moduledoc """
  `StatifierPersistence.Executions.active_children/2` (ADR-0008's
  2026-11-19 Amendment, point 7) over the in-memory adapter and the Ecto
  adapter on Postgres. The SQLite half, a host that sets
  `linkage_columns: true` and one that does not, is in
  `StatifierPersistence.Ecto.SqliteMigrationsTest`.

  The fixture is a loan whose children are stored directly, each with the
  linkage a durable subchart child carries: a renewal (an ordinary durable
  subchart) and a fan-out of overdue notices, one notice per status.
  """

  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: :in_memory}, %{adapter: :ecto}]

  alias Statifier.{Machine, MachineState}
  alias StatifierPersistence.{EctoHosts, Execution, Executions, Storage}
  alias StatifierPersistence.Execution.Linkage
  alias StatifierPersistence.Test.NoChildListingAdapter

  @notice """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending">
    <state id="pending">
      <transition event="notice.sent" target="sent"/>
    </state>
    <final id="sent"/>
  </scxml>
  """

  @loan "loan_copy_42"

  setup %{adapter: adapter} do
    {:ok, machine} = Statifier.compile(@notice)
    %{store: store(adapter), machine: machine, hash: Machine.identity(machine).content_hash}
  end

  # sabotage: dropped the status filter from active_children/2 -> red, the
  # parked-or-active match failed on the extra children; sorted by
  # execution id in place of invocation id and index -> red, notice 10 came
  # before notice 2; listed by the reserved key with an empty map in place
  # of the parent match -> red, the other children came back; kept a child
  # whose stored linkage does not read -> red, the hold came back. Each
  # verified red, reverted from a copy.
  test "answers the active and parked children, ordered by invocation then index", ctx do
    renewal = Linkage.new(@loan, "renewal", 0, ctx.hash)
    notice = &Linkage.new(@loan, "notice", &1, ctx.hash, 11, :all)

    # Inserted out of order, so the answer's order is the reader's.
    insert(ctx, notice.(10), :active)
    insert(ctx, renewal, :active)
    insert(ctx, notice.(5), :cancelled)
    insert(ctx, notice.(2), :needs_migration)
    insert(ctx, notice.(4), :failed)
    insert(ctx, notice.(3), :completed)

    # A grandchild is its own parent's child, and another loan's child is
    # that loan's.
    tenth_notice = Linkage.child_execution_id(@loan, "notice", 10)
    insert(ctx, Linkage.new(tenth_notice, "notice", 0, ctx.hash), :active)
    insert(ctx, Linkage.new("loan_copy_43", "renewal", 0, ctx.hash), :active)

    # A stored linkage that does not read as one names no invocation or
    # index, so it is no child this reader can place.
    hold = @loan <> "/hold/0"

    :ok =
      Storage.insert_execution(
        ctx.store,
        hold,
        MachineState.new(ctx.machine, session_id: "sess_" <> hold),
        :active,
        metadata: %{Linkage.reserved_key() => %{"parent_execution_id" => @loan}}
      )

    assert {:ok, children} = Executions.active_children(ctx.store, @loan)

    assert [
             %Execution{status: :needs_migration} = second,
             %Execution{status: :active} = tenth,
             %Execution{status: :active} = renewed
           ] = children

    assert second.execution_id == Linkage.child_execution_id(@loan, "notice", 2)
    assert tenth.execution_id == Linkage.child_execution_id(@loan, "notice", 10)
    assert renewed.execution_id == Linkage.child_execution_id(@loan, "renewal", 0)
    assert Enum.all?(children, &(&1.content_hash == ctx.hash))
  end

  # sabotage: answered `{:error, :execution_not_found}` from
  # active_children/2 when the listing came back empty -> red on the first
  # call. Verified red, reverted from a copy.
  test "an id with no children answers an empty list, stored or not", ctx do
    :ok =
      Storage.insert_execution(
        ctx.store,
        @loan,
        MachineState.new(ctx.machine, session_id: "sess_" <> @loan),
        :active
      )

    assert {:ok, []} = Executions.active_children(ctx.store, @loan)
    assert {:ok, []} = Executions.active_children(ctx.store, "loan_copy_never_stored")
  end

  # sabotage: answered `{:ok, []}` from active_children/2 when the listing
  # refused -> red, the refusal never arrived. Verified red, reverted from
  # a copy.
  test "a store that cannot list children refuses", _ctx do
    {:ok, store} = Storage.new(NoChildListingAdapter, [])

    assert {:error, :child_listing_unsupported} = Executions.active_children(store, @loan)
  end

  defp insert(ctx, %Linkage{} = linkage, status) do
    id =
      Linkage.child_execution_id(
        linkage.parent_execution_id,
        linkage.invoke_id,
        linkage.child_index
      )

    machine_state = MachineState.new(ctx.machine, session_id: "sess_" <> id)

    :ok =
      Storage.insert_execution(ctx.store, id, machine_state, status,
        metadata: Linkage.to_metadata(linkage)
      )
  end

  defp store(:in_memory) do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    store
  end

  defp store(:ecto) do
    {:ok, store} = Storage.new(Storage.Ecto, persistence: EctoHosts.Default, sandbox: true)
    :ok = Storage.Ecto.isolate(store.opts)
    store
  end
end

defmodule StatifierPersistence.ExecutionsActiveChildrenDoctest do
  use ExUnit.Case, async: true

  # sabotage: answered `{:ok, nil}` for an empty listing -> red, the
  # doctest printed `{:ok, nil}`. Verified red, reverted from a copy.
  doctest StatifierPersistence.Executions, only: [active_children: 2]
end
