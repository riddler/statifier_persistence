defmodule StatifierPersistence.Test.NoExecutionStatesAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that exports everything a
  fan-out needs except `list_execution_states_by_metadata/2`.

  The fixture for `Driver.start_child_at/6`'s `:execution_states_unsupported`
  refusal at open: the store enumerates children and stores an outcome
  payload, so a refusal here is provably about the indexed status
  projection alone - the read the settlement's "have all N settled?"
  question depends on.

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
  defdelegate supports_execution_outcome?(opts), to: InMemory

  @impl true
  defdelegate lock_execution(opts, execution_id, fun), to: InMemory
end
