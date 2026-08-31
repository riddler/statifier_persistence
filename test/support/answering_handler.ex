defmodule StatifierPersistence.Test.AnsweringHandler do
  @moduledoc """
  The smallest conformant `Statifier.Invoke.Handler` a `Statifier.Session`
  will accept for a non-`scxml` `<invoke type>`.

  It plans nothing at all - the session records the invocation from the
  `{:notify, {:invoke, _}}` instruction rather than from anything a handler
  returns - so the test that drives it is free to answer through
  `Statifier.Session.done_invocation/3` and
  `Statifier.Session.failed_invocation/3`, which is the pair
  `StatifierPersistence.Driver` claims to match.
  """

  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(_invoke, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}
end
