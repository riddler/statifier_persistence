defmodule StatifierPersistence.Ecto.Config do
  @moduledoc """
  The resolved configuration behind `use StatifierPersistence.Ecto`.

  ADR-0002 decision 3 requires that the generated schemas and the
  migrations helper take the same options and cannot disagree. This module
  is the single definition site that makes that true: `__using__/1` builds
  a `Config` at the host's compile time, and the migrations helper reads
  the same struct (via `for: HostModule`) or funnels literal options
  through the same `new/1`.

  Options:

    * `:repo` - required, the host's `Ecto.Repo` module
    * `:key` - the surrogate-key scheme, `:uxid` (default), `:uuid`,
      `:bigserial`, or `{module, opts}` implementing
      `StatifierPersistence.Ecto.KeyGenerator`
    * `:table_prefix` - prefix for the generated table names, default
      `"statifier_"`
    * `:tables` - per-table override map with keys `:charts`,
      `:positions`, `:runs`; an override replaces the whole name,
      prefix included
    * `:prefix` - the Postgres schema (Ecto's `@schema_prefix`), default
      `nil`

  Unknown options and unknown table keys raise `ArgumentError` - at the
  host's compile time when reached through `use`.
  """

  alias StatifierPersistence.Ecto.KeyGenerator

  @known_options [:repo, :key, :table_prefix, :tables, :prefix]
  @table_keys [:charts, :positions, :runs]

  @enforce_keys [:repo, :key, :table_prefix, :tables, :prefix]
  defstruct [:repo, :key, :table_prefix, :tables, :prefix]

  @typedoc "Resolved configuration for one host module."
  @type t :: %__MODULE__{
          repo: module(),
          key: {module(), keyword()},
          table_prefix: String.t(),
          tables: %{optional(KeyGenerator.table()) => String.t()},
          prefix: String.t() | nil
        }

  @doc """
  Validates and resolves the options `use StatifierPersistence.Ecto`
  accepts. Raises `ArgumentError` on anything malformed.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    reject_unknown!(opts)

    %__MODULE__{
      repo: fetch_repo!(opts),
      key: KeyGenerator.resolve(Keyword.get(opts, :key, :uxid)),
      table_prefix: validate_table_prefix!(Keyword.get(opts, :table_prefix, "statifier_")),
      tables: validate_tables!(Keyword.get(opts, :tables, %{})),
      prefix: validate_prefix!(Keyword.get(opts, :prefix))
    }
  end

  def new(other) do
    raise ArgumentError,
          "expected a keyword list of options, got: #{inspect(other)}"
  end

  @doc """
  The table name (source) for `table` under this configuration: the
  per-table override when one was given, otherwise the table prefix plus
  the table's own name.
  """
  @spec table(t(), KeyGenerator.table()) :: String.t()
  def table(%__MODULE__{} = config, table) when table in @table_keys do
    Map.get(config.tables, table, config.table_prefix <> Atom.to_string(table))
  end

  defp reject_unknown!(opts) do
    case Keyword.keys(opts) -- @known_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)} for use StatifierPersistence.Ecto; " <>
                "known options are #{inspect(@known_options)}"
    end
  end

  defp fetch_repo!(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_atom(repo) and not is_nil(repo) ->
        repo

      {:ok, other} ->
        raise ArgumentError, "the :repo option must be a repo module, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "the :repo option is required for use StatifierPersistence.Ecto"
    end
  end

  defp validate_table_prefix!(prefix) when is_binary(prefix), do: prefix

  defp validate_table_prefix!(other) do
    raise ArgumentError, "the :table_prefix option must be a string, got: #{inspect(other)}"
  end

  defp validate_tables!(tables) when is_map(tables) do
    Enum.each(tables, fn
      {key, name} when key in @table_keys and is_binary(name) ->
        :ok

      {key, name} when key in @table_keys ->
        raise ArgumentError,
              "the :tables override for #{inspect(key)} must be a string, " <>
                "got: #{inspect(name)}"

      {key, _name} ->
        raise ArgumentError,
              "unknown table key #{inspect(key)} in :tables; " <>
                "known keys are #{inspect(@table_keys)}"
    end)

    tables
  end

  defp validate_tables!(other) do
    raise ArgumentError, "the :tables option must be a map, got: #{inspect(other)}"
  end

  defp validate_prefix!(nil), do: nil
  defp validate_prefix!(prefix) when is_binary(prefix), do: prefix

  defp validate_prefix!(other) do
    raise ArgumentError,
          "the :prefix option (Postgres schema) must be a string or nil, " <>
            "got: #{inspect(other)}"
  end
end
