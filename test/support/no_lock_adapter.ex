defmodule StatifierPersistence.Test.NoLockAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that implements every required
  callback and deliberately does NOT export the optional `lock_run/3`.

  The fixture for the default serialization strategy's refusal arm:
  `StatifierPersistence.Serialization.AdapterLock` over this adapter must
  return `{:error, {:serialization, :not_supported}}`.
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
end
