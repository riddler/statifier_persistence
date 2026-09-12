defmodule StatifierPersistence.Serialization.AdapterLock do
  @moduledoc """
  The default `StatifierPersistence.Serialization` strategy (ADR-0004
  decision 5): per-execution ordering as the storage adapter's own lock.

  Its `config` is the `StatifierPersistence.Storage` handle itself.
  `with_execution/3` delegates to the adapter's optional
  `c:StatifierPersistence.Storage.Adapter.lock_execution/3` when the adapter
  exports it, and refuses with `{:error, {:serialization, :not_supported}}`
  when it does not - an adapter without a lock provides no ordering, and
  a silent fallback here would be the loop pretending otherwise.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Storage

  @impl StatifierPersistence.Serialization
  @spec with_execution(config :: term(), execution_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_execution(%Storage{} = store, execution_id, fun) do
    if Code.ensure_loaded?(store.adapter) and
         function_exported?(store.adapter, :lock_execution, 3) do
      store.adapter.lock_execution(store.opts, execution_id, fun)
    else
      {:error, {:serialization, :not_supported}}
    end
  end
end
