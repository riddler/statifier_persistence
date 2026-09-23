defmodule StatifierPersistence.Test.NoTombstoneReadAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that exports every callback
  `InMemory` does, retirement included, except the narrow tombstone read:
  neither `supports_retired_info?/1` nor `fetch_retired_info/2`.

  The fixture for the fallback arm of
  `StatifierPersistence.Storage.check_chart_retired/2`: an adapter that
  can carry a tombstone and declares no narrow read, so the conformance
  suite's facade cases prove the full-row path still refuses a retired
  chart. Without it the fallback's retired arm would run against no
  adapter in this repository, because both shipped adapters declare the
  narrow read and every other double here declines retirement.

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
  defdelegate lock_execution(opts, execution_id, fun), to: InMemory

  @impl true
  defdelegate supports_metadata?(opts), to: InMemory

  @impl true
  defdelegate list_executions_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate supports_execution_outcome?(opts), to: InMemory

  @impl true
  defdelegate list_execution_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate supports_content_hash_query?(opts), to: InMemory

  @impl true
  defdelegate count_executions_by_content_hash(opts, content_hash), to: InMemory

  @impl true
  defdelegate list_active_execution_ids_by_content_hash(opts, content_hash), to: InMemory

  @impl true
  defdelegate supports_chart_retirement?(opts), to: InMemory

  @impl true
  defdelegate retire_chart(opts, content_hash, retirement), to: InMemory
end
