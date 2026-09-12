defmodule StatifierPersistence.Test.OutcomeWindowSerialization do
  @moduledoc """
  A `StatifierPersistence.Serialization` strategy that reports whether a
  watched execution's own answer (`outcome_blob`) was already stored when an
  exclusion opened, and whether it was stored by the time it closed - the
  real `StatifierPersistence.Serialization.AdapterLock` exclusion executions
  unchanged in between.

  The fixture for sp-kl3's ordering half: a fan-out child's answer has to
  be recorded *inside* the parent's exclusion, so that every answer of one
  invocation is written and read in a single order and the settlement that
  records the last one is the settlement that sees them all. Recorded
  outside it, the answer would already be there when the exclusion opened,
  which is what this observes.

  It sends `{:exclusion, execution_id, recorded_on_entry?, recorded_on_exit?}` to
  the configured test process for every `with_execution/3` it wraps, and orders
  nothing itself.

  `config` is `{test_pid, StatifierPersistence.Storage.t(), watched_execution_id}`.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Serialization.AdapterLock
  alias StatifierPersistence.Storage

  @impl StatifierPersistence.Serialization
  @spec with_execution(config :: term(), execution_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_execution({test_pid, store, watched_execution_id}, execution_id, fun) do
    on_entry = recorded?(store, watched_execution_id)
    result = AdapterLock.with_execution(store, execution_id, fun)
    send(test_pid, {:exclusion, execution_id, on_entry, recorded?(store, watched_execution_id)})

    result
  end

  @spec recorded?(Storage.t(), String.t()) :: boolean()
  defp recorded?(store, execution_id) do
    case Storage.fetch_execution(store, execution_id) do
      {:ok, %{outcome_blob: blob}} -> is_binary(blob)
      _absent_or_error -> false
    end
  end
end
