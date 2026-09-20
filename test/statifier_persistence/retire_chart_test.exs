defmodule StatifierPersistence.RetireChartTest do
  @moduledoc """
  `StatifierPersistence.Executions.retire_chart/4`: the host-facing door
  of ADR-0012 decisions 5 and 6, over the in-memory adapter.

  The pin sources are what this module is mostly about, because they are
  the half the facade beneath it cannot see: the counts a host's own
  sources report, and the two ways a source fails to report one.

  The adapter half - what refuses, what the tombstone writes, what the
  two chart doors answer afterwards - is pinned for every adapter by the
  conformance template, and is only reached through here where the two
  layers have to agree.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.{Executions, Storage}

  alias StatifierPersistence.Test.{
    AddressPinSource,
    MalformedPinSource,
    RefusingPinSource,
    TimerQueuePinSource
  }

  # An ad impression that waits for its click: the chart whose bytes a
  # host eventually stops wanting to carry, and the one the pin-source
  # doubles are written around.
  @impression """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="served">
      <state id="served">
          <transition event="click" target="clicked"/>
      </state>
      <final id="clicked"/>
  </scxml>
  """

  setup do
    {:ok, store} = Storage.new(Storage.InMemory, [])
    {:ok, machine} = Statifier.compile(@impression)
    content_hash = Statifier.Machine.identity(machine).content_hash

    :ok = Storage.save_chart(store, machine, "chart-bytes")

    %{store: store, machine: machine, content_hash: content_hash}
  end

  describe "a drained chart" do
    # sabotage: in StatifierPersistence.Executions.retire_chart/4, drop
    # the Map.put(info, :content_hash, content_hash) from
    # retire_counted/4 -> red, the answer carried no :content_hash and
    # the first assertion below failed on a missing key. Reverted from a
    # copy.
    test "is retired, and the answer names the hash, the time and who asked", %{
      store: store,
      content_hash: content_hash
    } do
      at = DateTime.from_naive!(~N[2026-09-19 18:30:00.000000], "Etc/UTC")

      assert {:ok, retired} =
               Executions.retire_chart(store, content_hash, [],
                 retired_by: "ops@example.test",
                 now: at
               )

      assert retired.content_hash == content_hash
      assert retired.retired_at == at
      assert retired.retired_by == "ops@example.test"
    end

    # sabotage: in StatifierPersistence.Storage.retire_chart/3, default
    # retired_at to DateTime.utc_now() unconditionally instead of
    # honouring `now:` -> red, the retired_at read back was the wall
    # clock rather than the supplied instant. Reverted from a copy.
    test "answers the retired arm on both chart doors afterwards", %{
      store: store,
      machine: machine,
      content_hash: content_hash
    } do
      at = DateTime.from_naive!(~N[2026-09-19 18:30:00.000000], "Etc/UTC")

      assert {:ok, _retired} =
               Executions.retire_chart(store, content_hash, [],
                 retired_by: "ops@example.test",
                 now: at
               )

      assert {:error, {:chart_retired, info}} = Storage.fetch_chart(store, content_hash)
      assert info.retired_at == at
      assert info.retired_by == "ops@example.test"

      assert {:error, {:chart_retired, _info}} =
               Storage.save_chart(store, machine, "chart-bytes")
    end

    # The removal itself, read off the store rather than through a door
    # - every door answers the retired arm for this hash, so this is the
    # only place the bytes can be shown to be gone.
    #
    # sabotage: in the in-memory adapter's tombstone/4, leave
    # identity_blob and chart_blob alone and write only the two
    # tombstone values -> red, both blobs were still in the map after
    # the retirement the host asked for. Reverted from a copy.
    test "drops the bytes and keeps the entry and its hash", %{
      store: store,
      content_hash: content_hash
    } do
      assert {:ok, _retired} =
               Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

      stored = Agent.get(Keyword.fetch!(store.opts, :pid), &get_in(&1, [:charts, content_hash]))

      assert stored.content_hash == content_hash
      assert stored.identity_blob == nil
      assert stored.chart_blob == nil
      assert stored.retired_by == "ops@example.test"
    end

    # sabotage: in StatifierPersistence.Storage.retired_by!/1, return
    # the value unchecked instead of raising on a missing actor -> red,
    # the call retired the chart with a nil retired_by rather than
    # raising. Reverted from a copy.
    test "cannot be retired without naming who asked", %{
      store: store,
      content_hash: content_hash
    } do
      assert_raise ArgumentError, ~r/retired_by/, fn ->
        Executions.retire_chart(store, content_hash, [])
      end
    end

    # sabotage: in the in-memory adapter's retire_chart/3, drop the
    # nil-entry clause so an unknown hash falls through to the counts
    # -> red, a hash this store never held answered {:ok, ...}.
    # Reverted from a copy.
    test "a hash this store never held is a miss", %{store: store} do
      assert {:error, :chart_not_found} =
               Executions.retire_chart(store, "sha256:never-stored", [],
                 retired_by: "ops@example.test"
               )
    end
  end

  describe "the refusal" do
    # sabotage: in StatifierPersistence.Storage.Adapter.pinned?/1, drop
    # the `active > 0` term -> red, a chart with a live execution on it
    # was retired and the fetch below read the tombstone. Reverted from
    # a copy.
    test "carries this package's own counts while an execution is :active", %{
      store: store,
      content_hash: content_hash
    } do
      insert_execution(store, "impression-1", content_hash, :active)
      insert_execution(store, "impression-0", content_hash, :completed)

      assert {:error, {:pinned, counts}} =
               Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

      assert counts.executions == %{active: 1, completed: 1, failed: 0, cancelled: 0}
      assert counts.children == 0
      assert counts.positions == 0
      assert counts.sources == %{}
    end

    # sabotage: in StatifierPersistence.Executions.retire_chart/4, hand
    # PinSource.collect/3 an empty context (%{execution_ids: []}) rather
    # than the ids the listing answered -> red, the timer queue counted
    # zero pending timers and the retirement went through. Reverted from
    # a copy.
    test "carries each source's counts under that source's module name", %{
      store: store,
      content_hash: content_hash
    } do
      insert_execution(store, "impression-1", content_hash, :active)

      assert {:error, {:pinned, counts}} =
               Executions.retire_chart(store, content_hash, [TimerQueuePinSource],
                 retired_by: "ops@example.test"
               )

      assert counts.sources == %{TimerQueuePinSource => %{pending_timers: 1}}
    end

    # sabotage: in the in-memory adapter's retire_stored/4, pass %{} as
    # the sources argument to Adapter.pin_counts/3 instead of
    # retirement.sources -> red, the source that reported an address
    # neither refused nor appeared in the counts. Reverted from a copy.
    test "a source alone can pin a chart nothing in this package pins" do
      # A store of its own: the double's hash is not this suite's
      # impression chart, and the point of the case is a hash whose only
      # pin is outside this package.
      {:ok, store} = Storage.new(Storage.InMemory, [])
      hash = AddressPinSource.addressed_hash()

      :ok =
        store.adapter.save_chart(store.opts, %{
          content_hash: hash,
          identity_blob: <<1, 2, 3>>,
          chart_blob: <<4, 5, 6>>
        })

      assert {:error, {:pinned, counts}} =
               Executions.retire_chart(store, hash, [AddressPinSource],
                 retired_by: "ops@example.test"
               )

      assert counts.executions == %{active: 0, completed: 0, failed: 0, cancelled: 0}
      assert counts.sources == %{AddressPinSource => %{addresses: 1}}
    end

    # sabotage: in StatifierPersistence.Storage.Adapter.pinned?/1, drop
    # the `positions > 0` term -> red, a hash carrying a saved session's
    # position and no execution at all was retired, which strands
    # exactly the sessions ADR-0012's Context calls the dangerous half.
    # Reverted from a copy.
    test "a saved position pins a hash carrying no execution at all", %{
      store: store,
      machine: machine,
      content_hash: content_hash
    } do
      {machine_state, _effects} = Statifier.Interpreter.initialize(machine)
      :ok = Storage.save_position(store, "sess_impression", machine_state)

      assert {:error, {:pinned, counts}} =
               Executions.retire_chart(store, content_hash, [], retired_by: "ops@example.test")

      assert counts.positions == 1
      assert counts.executions == %{active: 0, completed: 0, failed: 0, cancelled: 0}
    end
  end

  describe "a source that could not answer" do
    # This is the sentence a host reads when it decides whether it may
    # retire, and the shape is the decision: a source failure is its own
    # arm and carries NO counts, because the walk stopped and no
    # complete count exists. Reporting the others under a tag that also
    # carries counts would let a host read a partial count as the whole,
    # which is the confusion ADR-0012 decision 4 exists to prevent.
    #
    # sabotage: in StatifierPersistence.Executions.ask_pin_sources/3,
    # answer {:ok, %{}} on a collect/3 failure instead of the
    # :pin_source_failed arm -> red, the raising source was read as
    # "nothing pins" and the chart was retired. Reverted from a copy.
    test "refuses on its own arm, naming only the failing module and carrying no counts", %{
      store: store,
      content_hash: content_hash
    } do
      # The second source would have answered a non-zero count for this
      # hash. Nothing in the refusal may suggest the walk reached it.
      sources = [RefusingPinSource, AddressPinSource]

      assert {:error, refusal} =
               Executions.retire_chart(store, content_hash, sources,
                 retired_by: "ops@example.test"
               )

      assert {:pin_source_failed, {RefusingPinSource, {:raised, %RuntimeError{}}}} = refusal

      refute match?({:pinned, _counts}, refusal)
      refute inspect(refusal) =~ "AddressPinSource"
      refute inspect(refusal) =~ "addresses"

      # And nothing was written: the chart is still readable.
      assert {:ok, _chart} = Storage.fetch_chart(store, content_hash)
    end

    # sabotage: in StatifierPersistence.PinSource.ask/3, return
    # {:ok, counts} without the valid_counts?/1 check -> red, the
    # malformed answer was collected as a count and the refusal never
    # came. Reverted from a copy.
    test "answers the same arm for an answer its own type rules out", %{
      store: store,
      content_hash: content_hash
    } do
      assert {:error, {:pin_source_failed, {MalformedPinSource, {:invalid_return, value}}}} =
               Executions.retire_chart(store, content_hash, [MalformedPinSource],
                 retired_by: "ops@example.test"
               )

      assert value == [pending_timers: 3]
      assert {:ok, _chart} = Storage.fetch_chart(store, content_hash)
    end
  end

  defp insert_execution(store, execution_id, content_hash, status) do
    :ok =
      store.adapter.insert_execution(store.opts, %{
        execution_id: execution_id,
        status: status,
        content_hash: content_hash,
        identity_blob: <<1, 2, 3>>,
        position_blob: <<7, 8, 9>>,
        failure: nil,
        metadata: %{},
        outcome_blob: nil
      })
  end
end
