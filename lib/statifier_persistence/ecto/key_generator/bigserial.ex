defmodule StatifierPersistence.Ecto.KeyGenerator.Bigserial do
  @moduledoc """
  Database-assigned auto-increment keys (ADR-0002 decision 2).

  Supported for hosts with that convention, not defaulted: a sequential
  id leaks row counts if exposed, and that is the host's trade to make.
  Schema fields are `:id` over `:bigserial` columns; `autogenerate/2`
  returns `nil` because the database assigns the key.
  """

  @behaviour StatifierPersistence.Ecto.KeyGenerator

  @impl true
  def ecto_type(_opts), do: :id

  @impl true
  def migration_type(_opts), do: :bigserial

  @impl true
  def autogenerate(_table, _opts), do: nil
end
