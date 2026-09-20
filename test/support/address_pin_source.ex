defmodule StatifierPersistence.Test.AddressPinSource do
  @moduledoc """
  A `StatifierPersistence.PinSource` standing in for a host's address table:
  it counts one address for the impression chart's hash and none for any
  other, and never looks at the context.

  Paired with `StatifierPersistence.Test.TimerQueuePinSource` it is the
  fixture for two sources reporting under their own module names, each with
  its own count name.

  Test-only support code.
  """

  @behaviour StatifierPersistence.PinSource

  @doc "The one content hash this double holds an address for."
  @spec addressed_hash() :: String.t()
  def addressed_hash, do: "impression-chart-hash"

  @impl true
  def pins(content_hash, _context) do
    if content_hash == addressed_hash(), do: %{addresses: 1}, else: %{addresses: 0}
  end
end
