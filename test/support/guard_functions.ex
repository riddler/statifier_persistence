defmodule StatifierPersistence.Test.GuardFunctions do
  @moduledoc """
  A host's `Predicator.FunctionProvider`: the one guard function the
  `function_providers:` tests register, `Approved/1`, true for `"yes"`
  and false for anything else.

  A chart that calls it compiles only with `function_providers:` naming
  this module (statifier checks the names a chart calls at compile), and
  evaluates it only on a position the list is stamped onto: without the
  stamp the `cond` that calls it is an `error.execution`, read as false.
  """

  @behaviour Predicator.FunctionProvider

  @impl Predicator.FunctionProvider
  def functions, do: %{"Approved" => {1, :approved}}

  @doc "`Approved(answer)`: whether `answer` is `\"yes\"`."
  @spec approved([term()], term()) :: {:ok, boolean()}
  def approved([answer], _context), do: {:ok, answer == "yes"}
end
