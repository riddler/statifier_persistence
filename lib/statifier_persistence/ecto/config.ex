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
    * `:blob_type` - the Ecto type applied to the three blob columns
      (`identity_blob`, `chart_blob`, `position_blob`), default
      `:binary` (the built-in `bytea` behaviour, unchanged). Pass a
      module implementing `Ecto.Type` for `field(name, Mod)`, or a
      `{module, opts}` tuple for an `Ecto.ParameterizedType` for
      `field(name, Mod, opts)` - the shape Ecto itself uses to declare a
      parameterized field. Keys and lookup columns (`content_hash`,
      `session_id`, `run_id`, `status`, `failure`) are never affected;
      only the three blob columns reach this option. Resolved and
      stored on the struct as `:binary` (bare) or `{module, opts}`
      (normalized, so a bare custom module becomes `{module, []}`) -
      one shape for downstream code to read.

  Unknown options and unknown table keys raise `ArgumentError` - at the
  host's compile time when reached through `use`.
  """

  alias StatifierPersistence.Ecto.KeyGenerator

  @known_options [:repo, :key, :table_prefix, :tables, :prefix, :blob_type]
  @table_keys [:charts, :positions, :runs]

  @enforce_keys [:repo, :key, :table_prefix, :tables, :prefix, :blob_type]
  defstruct [:repo, :key, :table_prefix, :tables, :prefix, :blob_type]

  @typedoc "Resolved configuration for one host module."
  @type t :: %__MODULE__{
          repo: module(),
          key: {module(), keyword()},
          table_prefix: String.t(),
          tables: %{optional(KeyGenerator.table()) => String.t()},
          prefix: String.t() | nil,
          blob_type: :binary | {module(), keyword()}
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
      prefix: validate_prefix!(Keyword.get(opts, :prefix)),
      blob_type: validate_blob_type!(Keyword.get(opts, :blob_type, :binary))
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

  defp validate_blob_type!(:binary), do: :binary

  defp validate_blob_type!(module) when is_atom(module) and not is_nil(module) do
    validate_blob_type!({module, []})
  end

  defp validate_blob_type!({module, opts}) when is_atom(module) and is_list(opts) do
    ensure_blob_type_loaded!(module)

    if Keyword.keyword?(opts) do
      if ecto_type?(module) or ecto_parameterized_type?(module) do
        {module, opts}
      else
        raise ArgumentError,
              "the :blob_type option module #{inspect(module)} must implement " <>
                "Ecto.Type or Ecto.ParameterizedType, got a module with neither " <>
                "type/0 nor (type/1 and init/1)"
      end
    else
      raise ArgumentError,
            "the :blob_type option's second element must be a keyword list, " <>
              "got: #{inspect(opts)}"
    end
  end

  defp validate_blob_type!(other) do
    raise ArgumentError,
          "the :blob_type option must be :binary, a module implementing Ecto.Type " <>
            "or Ecto.ParameterizedType, or a {module, opts} tuple, got: #{inspect(other)}"
  end

  defp ensure_blob_type_loaded!(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "the :blob_type option module #{inspect(module)} could not be loaded: " <>
                inspect(reason)
    end
  end

  defp ecto_type?(module), do: function_exported?(module, :type, 0)

  defp ecto_parameterized_type?(module) do
    function_exported?(module, :type, 1) and function_exported?(module, :init, 1)
  end

  @doc """
  The resolved `field/3` arguments for a blob column under this
  configuration: `[name, :binary]` for the default, or
  `[name, module, opts]` for a custom `:blob_type` (`opts` is `[]` for
  a bare custom module, since `field/3` treats an empty-opts
  parameterized call and a plain `Ecto.Type` call identically).
  """
  @spec blob_field_args(t(), atom()) :: [term(), ...]
  def blob_field_args(%__MODULE__{blob_type: :binary}, name), do: [name, :binary]

  def blob_field_args(%__MODULE__{blob_type: {module, opts}}, name),
    do: [name, module, opts]
end
