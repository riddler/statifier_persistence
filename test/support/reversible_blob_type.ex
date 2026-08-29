defmodule StatifierPersistence.Test.ReversibleBlobType do
  @moduledoc """
  Test-only support code: a generic reversible byte transform standing in
  for a real envelope-encrypting `Ecto.Type`, so the `:blob_type` config
  option (`StatifierPersistence.Ecto.Config`) can be proven end to end
  without depending on any encryption package.

  This is NOT encryption. `dump/1` and `load/1` XOR every byte of the
  binary against a fixed mask; XOR is its own inverse, so the round trip
  is byte-identical while the stored bytes differ from the input - enough
  to prove the type is really applied (StorageConformance's byte-identical
  contract, plus a raw-column check that the on-disk bytes are not the
  plaintext) without a real cryptography dependency in the test suite.
  """

  use Ecto.Type

  import Bitwise, only: [bxor: 2]

  @mask 0xA5

  @impl Ecto.Type
  @spec type() :: :binary
  def type, do: :binary

  @impl Ecto.Type
  @spec cast(term()) :: {:ok, binary()} | :error
  def cast(binary) when is_binary(binary), do: {:ok, binary}
  def cast(_other), do: :error

  @impl Ecto.Type
  @spec dump(term()) :: {:ok, binary()} | :error
  def dump(binary) when is_binary(binary), do: {:ok, transform(binary)}
  def dump(_other), do: :error

  @impl Ecto.Type
  @spec load(term()) :: {:ok, binary()} | :error
  def load(binary) when is_binary(binary), do: {:ok, transform(binary)}
  def load(_other), do: :error

  @doc """
  The transform itself, exposed so tests can compute the expected stored
  bytes independently of `dump/1`.
  """
  @spec transform(binary()) :: binary()
  def transform(binary) when is_binary(binary) do
    for <<byte <- binary>>, into: <<>>, do: <<bxor(byte, @mask)>>
  end
end
