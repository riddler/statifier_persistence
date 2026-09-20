defmodule StatifierPersistence.Test.MalformedPinSource do
  @moduledoc """
  A `StatifierPersistence.PinSource` that returns a list where the behaviour
  says a map of atom to non-negative integer.

  The fixture for the other half of ADR-0012 decision 4's refusal: a source
  whose answer cannot be read is a source that did not answer, and it must
  never be read as a zero either.

  It deliberately does not declare `@behaviour StatifierPersistence.PinSource`,
  because it does not implement it: the point of the double is an answer the
  behaviour's own type rules out.

  Test-only support code.
  """

  @spec pins(String.t(), StatifierPersistence.PinSource.context()) :: keyword()
  def pins(_content_hash, _context) do
    [pending_timers: 3]
  end
end
