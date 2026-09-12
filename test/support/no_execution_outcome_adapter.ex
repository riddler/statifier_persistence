defmodule StatifierPersistence.Test.NoExecutionOutcomeAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that exports everything a
  durable subchart needs - `list_executions_by_metadata/2` and
  `list_execution_states_by_metadata/2` included - and deliberately does NOT
  export `supports_execution_outcome?/1`.

  The fixture for `Driver.start_child_at/6`'s
  `:execution_outcome_unsupported` refusal at open: a store over this adapter
  can enumerate children and answer the status projection, so a refusal
  here is provably about the outcome payload alone.

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
  defdelegate list_executions_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate list_execution_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate lock_execution(opts, execution_id, fun), to: InMemory
end
