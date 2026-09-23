defmodule StatifierPersistence.Test.FailingTreeWriteAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` over any adapter whose
  `write_tree_migration/2` appends one park of an execution that is not
  stored to the writes it is handed, then hands them to the adapter it
  wraps.

  The fixture for a failure inside a tree migration's one unit
  (ADR-0015 decision 3): every write the command asked for is valid and
  comes first, so the wrapped adapter applies them before it reaches the
  one it cannot apply, and only its own unit - a rolled-back transaction,
  or an Agent state that is not replaced - keeps them from landing.

  It takes no `init/1` of its own worth calling: a test builds the
  `%StatifierPersistence.Storage{}` directly over an already-initialized
  store with `wrap/1`, so both handles reach the same rows.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage

  @missing "tree-write-missing-execution"

  @doc "A store over `store`'s own adapter and rows, with the failing unit."
  @spec wrap(Storage.t()) :: Storage.t()
  def wrap(%Storage{adapter: adapter, opts: opts}),
    do: %Storage{adapter: __MODULE__, opts: [inner: adapter, inner_opts: opts]}

  @doc "The execution id the appended park names, which is never stored."
  @spec missing() :: String.t()
  def missing, do: @missing

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def save_chart(opts, record), do: inner(opts).save_chart(inner_opts(opts), record)

  @impl true
  def fetch_chart(opts, hash), do: inner(opts).fetch_chart(inner_opts(opts), hash)

  @impl true
  def supports_retired_info?(opts), do: inner(opts).supports_retired_info?(inner_opts(opts))

  @impl true
  def fetch_retired_info(opts, hash), do: inner(opts).fetch_retired_info(inner_opts(opts), hash)

  @impl true
  def save_position(opts, record), do: inner(opts).save_position(inner_opts(opts), record)

  @impl true
  def fetch_position(opts, session_id),
    do: inner(opts).fetch_position(inner_opts(opts), session_id)

  @impl true
  def insert_execution(opts, record), do: inner(opts).insert_execution(inner_opts(opts), record)

  @impl true
  def fetch_execution(opts, id), do: inner(opts).fetch_execution(inner_opts(opts), id)

  @impl true
  def update_execution(opts, record), do: inner(opts).update_execution(inner_opts(opts), record)

  @impl true
  def supports_metadata?(opts), do: inner(opts).supports_metadata?(inner_opts(opts))

  @impl true
  def list_executions_by_metadata(opts, match),
    do: inner(opts).list_executions_by_metadata(inner_opts(opts), match)

  @impl true
  def lock_execution(opts, id, fun), do: inner(opts).lock_execution(inner_opts(opts), id, fun)

  @impl true
  def supports_tree_migration?(opts), do: inner(opts).supports_tree_migration?(inner_opts(opts))

  @impl true
  def write_tree_migration(opts, writes),
    do: inner(opts).write_tree_migration(inner_opts(opts), writes ++ [{:park, @missing}])

  defp inner(opts), do: Keyword.fetch!(opts, :inner)
  defp inner_opts(opts), do: Keyword.fetch!(opts, :inner_opts)
end
