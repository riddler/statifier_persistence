defmodule StatifierPersistence do
  @moduledoc """
  Durable stepper and storage adapters for Statifier.
  """

  @doc """
  The running version of this package.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:statifier_persistence, :vsn) |> to_string()
  end
end
