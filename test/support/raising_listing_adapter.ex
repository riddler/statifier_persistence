defmodule StatifierPersistence.Test.RaisingListingAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` whose
  `list_executions_by_metadata/2` raises.

  The fixture for ruling C5's real content: a fan-out's settlement asks
  "have all N children settled?" once per child, and it must ask through
  the indexed status projection rather than the materialising listing.
  A test that only asserted the projection returns the right rows would
  pass just as well if the settlement called both. This adapter turns the
  wrong call into a failure.

  Test-only support code.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage.InMemory

  @impl true
  defdelegate init(opts), to: InMemory

  @impl true
  defdelegate save_chart(opts, chart_record), to: InMemory

  @impl true
  defdelegate fetch_chart(opts, content_hash), to: InMemory

  @impl true
  defdelegate save_position(opts, position_record), to: InMemory

  @impl true
  defdelegate fetch_position(opts, session_id), to: InMemory

  @impl true
  defdelegate insert_execution(opts, execution_record), to: InMemory

  @impl true
  defdelegate fetch_execution(opts, execution_id), to: InMemory

  @impl true
  defdelegate update_execution(opts, execution_record), to: InMemory

  @impl true
  defdelegate supports_metadata?(opts), to: InMemory

  @impl true
  defdelegate supports_execution_outcome?(opts), to: InMemory

  @impl true
  defdelegate list_execution_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate lock_execution(opts, execution_id, fun), to: InMemory

  @impl true
  def list_executions_by_metadata(_opts, _metadata) do
    raise "list_executions_by_metadata/2 was called where the projection was required"
  end
end
