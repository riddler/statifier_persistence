defmodule StatifierPersistence.Test.RaisingListingAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` whose
  `list_runs_by_metadata/2` raises.

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
  defdelegate insert_run(opts, run_record), to: InMemory

  @impl true
  defdelegate fetch_run(opts, run_id), to: InMemory

  @impl true
  defdelegate update_run(opts, run_record), to: InMemory

  @impl true
  defdelegate supports_metadata?(opts), to: InMemory

  @impl true
  defdelegate supports_run_outcome?(opts), to: InMemory

  @impl true
  defdelegate list_run_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate lock_run(opts, run_id, fun), to: InMemory

  @impl true
  def list_runs_by_metadata(_opts, _metadata) do
    raise "list_runs_by_metadata/2 was called where the projection was required"
  end
end
