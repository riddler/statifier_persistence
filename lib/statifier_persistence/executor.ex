defmodule StatifierPersistence.Executor do
  @moduledoc """
  The seam through which a stepped run's effects reach the host (ADR-0004
  decision 4).

  An executor is a module implementing this behaviour, or an arity-2 fun
  accepted anywhere a module is. `StatifierPersistence.Runs` invokes it once
  per effect, in the effect list's own order, for every effect the lifecycle
  does not consume itself.
  """

  @typedoc """
  What `c:execute/2` receives alongside each effect: the run's
  caller-supplied id and the content hash of the chart revision it runs -
  enough to key idempotency storage and telemetry without another lookup.
  """
  @type context :: %{run_id: String.t(), content_hash: String.t()}

  @typedoc """
  An executor: a module implementing this behaviour, or an arity-2 fun with
  `c:execute/2`'s own signature, accepted anywhere a module is (ADR-0004
  decision 4).
  """
  @type t :: module() | (Statifier.Effect.t(), context() -> :ok | {:error, term()})

  @doc """
  Executes one effect against the outside world.

  The contract, per ADR-0004 decisions 3 and 4:

  - Effects arrive in list order, one call per effect.
  - Only the public effect vocabulary (`t:Statifier.Effect.t/0`) ever
    arrives - never Session instruction tuples (st-ADR-0054 decision 1).
  - `:done` and `:budget_exhausted` never arrive: the lifecycle consumes
    both into run status itself.
  - At-least-once redelivery is the contract: a crash between step and
    persist re-drives the same event and re-emits the same effects carrying
    identical deterministic keys (st-ADR-0054 decision 3, st-ADR-0059's
    `timer_counter` ordinal). The loop never dedupes; idempotency by that
    key is the implementer's.
  """
  @callback execute(effect :: Statifier.Effect.t(), context :: context()) ::
              :ok | {:error, term()}

  # Package-internal: normalizes the module-or-fun shapes of `t:t/0` into
  # one call. `StatifierPersistence.Runs` is the only intended caller.
  @doc false
  @spec run(executor :: t(), effect :: Statifier.Effect.t(), context :: context()) ::
          :ok | {:error, term()}
  def run(executor, effect, context) when is_atom(executor),
    do: executor.execute(effect, context)

  def run(executor, effect, context) when is_function(executor, 2),
    do: executor.(effect, context)
end
