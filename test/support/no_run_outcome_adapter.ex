defmodule StatifierPersistence.Test.NoRunOutcomeAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that exports everything a
  durable subchart needs - `list_runs_by_metadata/2` and
  `list_run_states_by_metadata/2` included - and deliberately does NOT
  export `supports_run_outcome?/1`.

  The fixture for `Driver.start_child_at/6`'s
  `:run_outcome_unsupported` refusal at open: a store over this adapter
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
  defdelegate insert_run(opts, run_record), to: InMemory

  @impl true
  defdelegate fetch_run(opts, run_id), to: InMemory

  @impl true
  defdelegate update_run(opts, run_record), to: InMemory

  @impl true
  defdelegate supports_metadata?(opts), to: InMemory

  @impl true
  defdelegate list_runs_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate list_run_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate lock_run(opts, run_id, fun), to: InMemory
end
