defmodule StatifierPersistence.Test.TimerQueuePinSource do
  @moduledoc """
  A `StatifierPersistence.PinSource` standing in for a host's durable timer
  queue: it counts one pending timer per `:active` execution it is handed,
  and never looks at the content hash.

  It is the fixture for the half of ADR-0012 decision 4 that says why
  `context` carries execution ids - a timer queue knows executions and never
  knows hashes, and this double answers from the ids alone.

  Test-only support code.
  """

  @behaviour StatifierPersistence.PinSource

  @impl true
  def pins(_content_hash, %{execution_ids: execution_ids}) do
    %{pending_timers: length(execution_ids)}
  end
end
