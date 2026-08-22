defmodule StatifierPersistence.Test.FlakyAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` whose `update_run/2` fails exactly
  once with `{:error, {:adapter, :injected}}`, then delegates normally.

  The at-least-once proof's fixture: the injected failure lands between
  effect execution and persist, exactly where a crash would, so re-driving
  the same event must re-emit the same effects with identical deterministic
  keys (st-ADR-0054 decision 3, st-ADR-0059).
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage.InMemory

  @impl true
  def init(opts) do
    with {:ok, inner} <- InMemory.init(opts) do
      {:ok, trip} = Agent.start_link(fn -> false end)
      {:ok, %{inner: inner, trip: trip}}
    end
  end

  @impl true
  def save_chart(%{inner: inner}, chart_record), do: InMemory.save_chart(inner, chart_record)

  @impl true
  def fetch_chart(%{inner: inner}, content_hash), do: InMemory.fetch_chart(inner, content_hash)

  @impl true
  def save_position(%{inner: inner}, position_record),
    do: InMemory.save_position(inner, position_record)

  @impl true
  def fetch_position(%{inner: inner}, session_id),
    do: InMemory.fetch_position(inner, session_id)

  @impl true
  def insert_run(%{inner: inner}, run_record), do: InMemory.insert_run(inner, run_record)

  @impl true
  def fetch_run(%{inner: inner}, run_id), do: InMemory.fetch_run(inner, run_id)

  @impl true
  def lock_run(%{inner: inner}, run_id, fun), do: InMemory.lock_run(inner, run_id, fun)

  @impl true
  def update_run(%{inner: inner, trip: trip}, run_record) do
    if Agent.get_and_update(trip, fn tripped -> {tripped, true} end) do
      InMemory.update_run(inner, run_record)
    else
      {:error, {:adapter, :injected}}
    end
  end
end
