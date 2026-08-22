defmodule StatifierPersistence.Serialization.AdapterLock do
  @moduledoc """
  The default `StatifierPersistence.Serialization` strategy (ADR-0004
  decision 5): per-run ordering as the storage adapter's own lock.

  Its `config` is the `StatifierPersistence.Storage` handle itself.
  `with_run/3` delegates to the adapter's optional
  `c:StatifierPersistence.Storage.Adapter.lock_run/3` when the adapter
  exports it, and refuses with `{:error, {:serialization, :not_supported}}`
  when it does not - an adapter without a lock provides no ordering, and
  a silent fallback here would be the loop pretending otherwise.
  """

  @behaviour StatifierPersistence.Serialization

  alias StatifierPersistence.Storage

  @impl StatifierPersistence.Serialization
  @spec with_run(config :: term(), run_id :: String.t(), fun :: (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_run(%Storage{} = store, run_id, fun) do
    if Code.ensure_loaded?(store.adapter) and
         function_exported?(store.adapter, :lock_run, 3) do
      store.adapter.lock_run(store.opts, run_id, fun)
    else
      {:error, {:serialization, :not_supported}}
    end
  end
end
