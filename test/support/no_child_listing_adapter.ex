defmodule StatifierPersistence.Test.NoChildListingAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that implements every callback
  including the optional `lock_run/3` and `supports_metadata?/1`, and
  deliberately does NOT export the optional `list_runs_by_metadata/2`.

  The fixture for `Driver`'s durable-subchart refusal-at-open: a store over
  this adapter serializes and stores metadata exactly as `InMemory` does, so
  a start_child refusal here is provably about
  `Storage.child_listing_supported?/1` alone, not about the serialization
  refusal `StatifierPersistence.Test.NoLockAdapter` exercises instead.
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
  defdelegate lock_run(opts, run_id, fun), to: InMemory
end
