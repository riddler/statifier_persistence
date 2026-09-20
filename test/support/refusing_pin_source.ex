defmodule StatifierPersistence.Test.RefusingPinSource do
  @moduledoc """
  A `StatifierPersistence.PinSource` whose `pins/2` raises.

  The fixture for ADR-0012 decision 4's refusal: a source that cannot answer
  says so by raising, and a raise must never be read as a zero.

  Test-only support code.
  """

  @behaviour StatifierPersistence.PinSource

  @impl true
  def pins(_content_hash, _context) do
    raise "the timer queue is unreachable"
  end
end
