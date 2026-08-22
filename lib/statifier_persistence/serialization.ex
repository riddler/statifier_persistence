defmodule StatifierPersistence.Serialization do
  @moduledoc """
  The per-run serialization strategy behaviour (ADR-0004 decision 5):
  the seam through which concurrent deliveries to one run are ordered.

  `StatifierPersistence.Runs` runs its whole fetch-to-persist tail inside
  `c:with_run/3`, so the ordering guarantee lives in the strategy, not in
  the loop. Strategy selection is a `StatifierPersistence.Runs` option on
  `create/4`, `step/5`, and `fail/4` - `serialization: {module, config}` -
  defaulting to `{StatifierPersistence.Serialization.AdapterLock, store}`,
  which delegates to the storage adapter's optional
  `c:StatifierPersistence.Storage.Adapter.lock_run/3`. A host that orders
  deliveries some other way (a single job-queue consumer per run id, for
  one) swaps the strategy without touching the loop: the guarantee moves,
  the API does not.
  """

  @doc """
  Runs `fun` under this strategy's per-run exclusion for `run_id`,
  returning `{:ok, fun.()}` or the strategy's own refusal.

  The guarantee a strategy must provide: for one `run_id`, two `with_run/3`
  bodies never overlap, and completed bodies are observed in execution
  order - a body that finishes before another starts is durable before the
  later body loads. It explicitly does NOT promise cross-run ordering or
  fairness: bodies for different run ids may interleave freely, and a
  contended run id may serve waiters in any order.
  """
  @callback with_run(config :: term(), run_id :: String.t(), fun :: (-> result)) ::
              {:ok, result} | {:error, term()}
            when result: var
end
