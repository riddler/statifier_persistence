defmodule StatifierPersistence do
  @moduledoc """
  Durable stepper and storage adapters for Statifier.

  This module itself carries only `version/0`. The package's surface is four
  modules, and the README's worked example drives all of them in order:

  - `StatifierPersistence.Storage` - the identity-guarded facade over charts,
    positions, and run records. Every load is guarded against the chart
    revision that wrote it; there is no unguarded path.
  - `StatifierPersistence.Storage.Adapter` - the behaviour a backing store
    implements. `StatifierPersistence.Storage.InMemory` is the reference
    implementation, `StatifierPersistence.Storage.Ecto` the Postgres one, and
    `StatifierPersistence.Testing.StorageConformance` holds any third to the
    same bar.
  - `StatifierPersistence.Runs` - the lifecycle: `create/4`, `step/5`,
    `fail/4`, each running load -> step -> execute effects -> persist in
    ADR-0004 decision 3's fixed order, with no live Session process.
  - `StatifierPersistence.Executor` - the seam every effect crosses on its way
    to the host, as a module or a bare arity-2 fun.

  `StatifierPersistence.Serialization` is the fifth, and usually invisible:
  it orders concurrent deliveries to one run, defaulting to the adapter's own
  `lock_run/3`.
  """

  @doc """
  The running version of this package.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:statifier_persistence, :vsn) |> to_string()
  end
end
