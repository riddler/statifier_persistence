defmodule StatifierPersistence.Test.ScopePlacement do
  @moduledoc """
  Places an execution's rows into a scope for the storage conformance
  suite's `prune_scope:` option: writes each scope column onto the
  execution's row and onto every input log row it has, by table name,
  because the package never writes a host's `:leading_columns` and its
  generated schemas do not declare them. Test-only support code.
  """

  import Ecto.Query, only: [from: 2, put_query_prefix: 2]

  @spec place(keyword(), String.t(), keyword()) :: :ok
  def place(opts, execution_id, scope) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = Keyword.fetch!(opts, :execution_schema).__schema__(:prefix)

    for table <- [Keyword.fetch!(opts, :executions_table), Keyword.fetch!(opts, :inputs_table)] do
      query = from(r in table, where: r.execution_id == ^execution_id)
      query = if prefix, do: put_query_prefix(query, prefix), else: query
      repo.update_all(query, set: scope)
    end

    :ok
  end
end
