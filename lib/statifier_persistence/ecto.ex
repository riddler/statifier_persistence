if Code.ensure_loaded?(Ecto) do
  defmodule StatifierPersistence.Ecto do
    @moduledoc """
    Compile-time Ecto configuration on the host's own module (ADR-0002).

    A host declares its persistence module once:

        defmodule MyApp.Persistence do
          use StatifierPersistence.Ecto, repo: MyApp.Repo
        end

    and gets, with zero further options: the resolved configuration
    readable via `MyApp.Persistence.__statifier_persistence__/1`, and
    four Ecto schema modules - `MyApp.Persistence.Chart`,
    `MyApp.Persistence.Position`, `MyApp.Persistence.Execution`,
    `MyApp.Persistence.Input` - over the `statifier_charts` /
    `statifier_positions` / `statifier_runs` / `statifier_inputs` tables
    with UXID string primary keys (`chart_` / `pos_` / `exec_` / `input_`
    prefixes).

    Every knob is compile-time, on this `use`, never in application env
    (ADR-0002 decision 3), and the migrations helper consumes the same
    resolved configuration so schemas and DDL cannot disagree. See
    `StatifierPersistence.Ecto.Config` for the options (`:key`,
    `:table_prefix`, `:tables`, `:prefix`, `:blob_type`).

    The engine identity columns (`content_hash`, `session_id`, `execution_id`)
    are stored verbatim as strings and are never touched by the
    configured key scheme - ADR-0002 decision 1.

    The execution schema also carries `metadata`, the optional opaque map of
    host identities ADR-0006 grants, as a `jsonb` column (V02 of the
    migrations helper). It holds identities only, never personal data:
    `:blob_type` does not reach it, so anything filed there is at rest in
    the clear no matter how the blob columns are configured.

    `:blob_type` reaches the payload columns and nothing else:
    `identity_blob`, `chart_blob`, `position_blob`, `outcome_blob`, and
    `input_blob` on the inputs table (ADR-0010 decision 4). A host
    wanting encryption at rest for those columns passes a custom
    `Ecto.Type` or `Ecto.ParameterizedType` there and gets it applied
    with zero further wiring. The identity and lookup columns
    (`content_hash`, `session_id`, `execution_id`, `status`, `failure`, and
    the input log's `seq` and `door`) stay plain regardless - the identity guard and the unique indexes
    depend on reading them back verbatim, and `metadata` stays `jsonb`
    regardless for the same reason: it is the column a host queries
    (ADR-0006 decision 3).

    The inputs table is ADR-0010's per-execution input log: one row per input
    the interpreter saw, carrying the execution it belongs to, its dense
    zero-based `seq`, the public `door` it entered by, and the opaque
    `input_blob`. A `nil` `input_blob` is decision 6's closed marker. The
    log holds document payload - an event's `data` is the host's own
    values - which is why `:blob_type` reaches `input_blob` and why
    turning the log on is a data-retention decision rather than a
    debugging switch (`StatifierPersistence.Storage.Adapter`'s moduledoc).
    """

    alias StatifierPersistence.Ecto.Config

    @schema_modules [
      {Chart, :charts},
      {Position, :positions},
      {Execution, :runs},
      {Input, :inputs}
    ]

    # The columns :blob_type reaches - identity/lookup columns never do
    # (moduledoc, Config's :blob_type option).
    @blob_columns [
      :identity_blob,
      :chart_blob,
      :position_blob,
      :outcome_blob,
      :input_blob
    ]

    # The storage contract's field set is the column list (ADR-0003
    # decision 3); the migrations helper's V01 DDL mirrors these exactly.
    # Blob columns are typed :binary here; schema_ast/3 substitutes the
    # configured :blob_type for any column in @blob_columns.
    @fields %{
      charts: [content_hash: :string, identity_blob: :binary, chart_blob: :binary],
      positions: [
        session_id: :string,
        content_hash: :string,
        identity_blob: :binary,
        position_blob: :binary
      ],
      runs: [
        execution_id: :string,
        status: :string,
        content_hash: :string,
        identity_blob: :binary,
        position_blob: :binary,
        failure: :string,
        session_id: :string,
        metadata: :map,
        outcome_blob: :binary
      ],
      inputs: [
        execution_id: :string,
        seq: :integer,
        door: :string,
        input_blob: :binary
      ]
    }

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @statifier_persistence_config StatifierPersistence.Ecto.Config.new(opts)

        @doc false
        @spec __statifier_persistence__(:config | :repo) ::
                StatifierPersistence.Ecto.Config.t() | module()
        def __statifier_persistence__(:config), do: @statifier_persistence_config
        def __statifier_persistence__(:repo), do: @statifier_persistence_config.repo

        StatifierPersistence.Ecto.__define_schemas__(__MODULE__, @statifier_persistence_config)
      end
    end

    @doc false
    @spec __define_schemas__(module(), Config.t()) :: :ok
    def __define_schemas__(host, %Config{} = config) do
      for {name, table} <- @schema_modules do
        Module.create(
          Module.concat(host, name),
          schema_ast(host, table, config),
          Macro.Env.location(__ENV__)
        )
      end

      :ok
    end

    defp schema_ast(host, table, %Config{} = config) do
      fields =
        for {field, type} <- Map.fetch!(@fields, table) do
          args =
            cond do
              field in @blob_columns ->
                Config.blob_field_args(config, field)

              # ADR-0011 decision 2 renames the schema field; decision 3's V06
              # renames the column it reads. sp-op4 lands the first and sp-j2y
              # the second, so until V06 is applied the field is mapped onto
              # the column it still has. sp-j2y removes this `source:` with the
              # migration.
              field == :execution_id ->
                [field, type, [source: :run_id]]

              true ->
                [field, type]
            end

          quote do: field(unquote_splicing(args))
        end

      quote do
        @moduledoc """
        Ecto schema for the `#{unquote(Config.table(config, table))}` table,
        generated by `use StatifierPersistence.Ecto` on
        `#{unquote(inspect(host))}`.
        """

        use Ecto.Schema

        @schema_prefix unquote(config.prefix)
        @primary_key unquote(Macro.escape(primary_key(table, config)))
        schema unquote(Config.table(config, table)) do
          unquote_splicing(fields)
          timestamps(type: :utc_datetime_usec)
        end
      end
    end

    defp primary_key(table, %Config{key: {key_mod, key_opts}}) do
      type = key_mod.ecto_type(key_opts)

      case key_mod.autogenerate(table, key_opts) do
        # Database-assigned (e.g. bigserial): read the key back on insert.
        nil -> {:id, type, autogenerate: false, read_after_writes: true}
        {_m, _f, _a} = mfa -> {:id, type, autogenerate: mfa}
      end
    end
  end
end
