defmodule StatifierPersistence.StorageTest do
  use ExUnit.Case, async: true

  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.InMemory

  defmodule FailingAdapter do
    @moduledoc false
    @behaviour StatifierPersistence.Storage.Adapter

    @impl StatifierPersistence.Storage.Adapter
    def init(_opts), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def save_chart(_opts, _chart_record), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def fetch_chart(_opts, _content_hash), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def save_position(_opts, _position_record), do: {:error, {:adapter, :boom}}

    @impl StatifierPersistence.Storage.Adapter
    def fetch_position(_opts, _session_id), do: {:error, {:adapter, :boom}}
  end

  # The conformance suite (test/statifier_persistence/storage/in_memory_conformance_test.exs,
  # via StatifierPersistence.Testing.StorageConformance) covers every guard
  # and round-trip assertion this module used to make - the guarded round
  # trip, the cross-revision mismatch, corrupt bytes, and every
  # unidentified-machine refusal - across every adapter. What is left here
  # is genuinely specific to this module's own construction: `new/2`.

  # sabotage: in Storage.new/2, ignore adapter.init/1's result entirely and
  # always return {:ok, %__MODULE__{adapter: adapter, opts: opts}} with the
  # caller-supplied opts unchanged -> red, this test's assertion that the
  # built store threads InMemory's own :pid through would fail, and the
  # next test's assertion on the {:error, _} arm would fail too, because
  # there would be no way for init/1's own failure to reach the caller.
  # Verified red (both tests below), reverted.
  test "new/2 initializes the adapter and returns a store carrying its opts" do
    assert {:ok, store} = Storage.new(InMemory, [])

    assert %Storage{adapter: InMemory, opts: opts} = store
    assert is_pid(Keyword.fetch!(opts, :pid))
  end

  # sabotage: same mutation as the test above.
  test "new/2 returns the adapter's own init/1 failure unchanged" do
    assert {:error, {:adapter, :boom}} = Storage.new(FailingAdapter, [])
  end
end
