defmodule StatifierPersistence.Test.Dialyzer.FailWithDriver do
  # An embedder's calls to `StatifierPersistence.Executions.fail/4`, compiled
  # where Dialyzer reads them.
  #
  # `mix dialyzer` analyses the modules of the environment it runs in, and
  # `test/support/` is compiled for `:test` only, so a caller there is one
  # Dialyzer never sees. This directory is compiled for `:dev` as well
  # (`elixirc_paths/1` in `mix.exs`) and is never in the package, so the
  # gate's Dialyzer stage reads these functions as a host's code is read.
  # `@moduledoc false` because `mix docs` also runs in `:dev`.
  #
  # Each function passes `fail/4` a literal option list, the shape a host
  # writes, because a literal list is what Dialyzer checks against the
  # success typing a narrower spec down the call leaves behind. A `driver:`
  # that a spec on the fail path does not admit makes these calls ones that
  # "will never return", and the gate's Dialyzer stage goes red on them.
  #
  # `test/statifier_persistence/executions_fail_driver_dialyzer_test.exs`
  # runs the same functions, so the fixture is also shown to work.
  @moduledoc false

  alias StatifierPersistence.{Driver, Execution, Executions, Storage}
  alias StatifierPersistence.Serialization.AdapterLock

  @typep result ::
           {:ok, Execution.t()} | {:discarded, Execution.t()} | {:error, Executions.error()}

  # `driver:` alone.
  @spec with_driver(Storage.t(), Statifier.Machine.t(), Executions.execution_id()) :: result()
  def with_driver(store, machine, execution_id) do
    Executions.fail(store, execution_id, "host:abandoned", driver: driver(store, machine))
  end

  # Both options `fail/4` documents.
  @spec with_driver_and_serialization(
          Storage.t(),
          Statifier.Machine.t(),
          Executions.execution_id()
        ) :: result()
  def with_driver_and_serialization(store, machine, execution_id) do
    Executions.fail(store, execution_id, "host:abandoned",
      driver: driver(store, machine),
      serialization: {AdapterLock, store}
    )
  end

  @spec driver(Storage.t(), Statifier.Machine.t()) :: Driver.t()
  defp driver(store, machine) do
    Driver.new(store, machine, dispatch: fn _type, _params, _context -> :pending end)
  end
end
