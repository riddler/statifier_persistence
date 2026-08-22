if Code.ensure_loaded?(Ecto) do
  defmodule StatifierPersistence.Ecto.KeyGenerator.UUIDv7 do
    @moduledoc """
    RFC 9562 UUIDv7 keys (ADR-0002 decision 2).

    `:uuid` keys are generated as UUIDv7, not v4: random keys fragment
    b-tree indexes, and v7's 48-bit millisecond timestamp keeps insertion
    locality. Generation is implemented here - `Ecto.UUID` generates v4,
    and a dependency for one function is not worth taking. Schema fields
    are `Ecto.UUID` over `:uuid` columns.
    """

    @behaviour StatifierPersistence.Ecto.KeyGenerator

    @impl true
    def ecto_type(_opts), do: Ecto.UUID

    @impl true
    def migration_type(_opts), do: :uuid

    @impl true
    def autogenerate(_table, _opts), do: {__MODULE__, :generate, []}

    @doc """
    Generates an RFC 9562 UUIDv7 as a canonical hyphenated string.

    Layout: 48-bit Unix millisecond timestamp, 4-bit version (7), 12
    random bits, 2-bit variant (`10`), 62 random bits.
    """
    @spec generate() :: Ecto.UUID.t()
    def generate do
      <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
      raw = <<System.system_time(:millisecond)::48, 7::4, rand_a::12, 2::2, rand_b::62>>
      {:ok, encoded} = Ecto.UUID.load(raw)
      encoded
    end
  end
end
