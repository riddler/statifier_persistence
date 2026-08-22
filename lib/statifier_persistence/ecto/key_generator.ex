defmodule StatifierPersistence.Ecto.KeyGenerator do
  @moduledoc """
  Behaviour a surrogate-key scheme implements for the Ecto layer.

  ADR-0002 makes the surrogate primary keys of this package's tables
  compile-time configurable per host: `:uxid` (the default), `:uuid`
  (UUIDv7), `:bigserial`, or any `{module, opts}` implementing this
  behaviour. A key scheme must answer three questions - the Ecto schema
  field type, the migration column type, and how a key is generated (or
  that the database assigns it) - and both the generated schemas and the
  migrations helper read their answers from the same resolved generator,
  so the two cannot disagree.

  Engine identities (the chart content hash, the engine session id, the
  caller's run id) are stored verbatim and are not touched by any key
  generator - ADR-0002 decision 1.

  The bundled implementations:

    * `StatifierPersistence.Ecto.KeyGenerator.UXID` - k-sortable strings
      with per-table prefixes (`chart_`, `pos_`, `run_`)
    * `StatifierPersistence.Ecto.KeyGenerator.UUIDv7` - RFC 9562 UUIDv7
    * `StatifierPersistence.Ecto.KeyGenerator.Bigserial` -
      database-assigned auto-increment
  """

  @typedoc "The tables whose rows carry a generated surrogate key."
  @type table :: :charts | :positions | :runs

  @typedoc "ADR-0002's key option spellings."
  @type spelling :: :uxid | :uuid | :bigserial | {module(), keyword()}

  @doc """
  The Ecto schema field type for the primary key, e.g. `:string`,
  `Ecto.UUID`, or `:id`.
  """
  @callback ecto_type(opts :: keyword()) :: atom()

  @doc """
  The column type the migrations helper emits for the primary key, e.g.
  `:text`, `:uuid`, or `:bigserial`.
  """
  @callback migration_type(opts :: keyword()) :: atom()

  @doc """
  The `{module, function, args}` an Ecto schema uses to autogenerate a
  primary key for a row of `table`, or `nil` when the database assigns
  the key itself.
  """
  @callback autogenerate(table(), opts :: keyword()) ::
              {module(), atom(), [term()]} | nil

  @doc """
  Resolves one of ADR-0002's key option spellings to `{module, opts}`.

  `:uxid`, `:uuid`, and `:bigserial` map onto the bundled
  implementations. A `{module, opts}` tuple passes through after a check
  that `module` declares this behaviour; anything else raises
  `ArgumentError`.
  """
  @spec resolve(spelling()) :: {module(), keyword()}
  def resolve(:uxid), do: {StatifierPersistence.Ecto.KeyGenerator.UXID, []}
  def resolve(:uuid), do: {StatifierPersistence.Ecto.KeyGenerator.UUIDv7, []}
  def resolve(:bigserial), do: {StatifierPersistence.Ecto.KeyGenerator.Bigserial, []}

  def resolve({module, opts}) when is_atom(module) and is_list(opts) do
    if implements_behaviour?(module) do
      {module, opts}
    else
      raise ArgumentError,
            "#{inspect(module)} does not implement the " <>
              "StatifierPersistence.Ecto.KeyGenerator behaviour"
    end
  end

  def resolve(other) do
    raise ArgumentError,
          "unknown key option #{inspect(other)}; expected :uxid, :uuid, " <>
            ":bigserial, or {module, opts} implementing " <>
            "StatifierPersistence.Ecto.KeyGenerator"
  end

  defp implements_behaviour?(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end
