if Code.ensure_loaded?(Ecto) do
  defmodule StatifierPersistence.Storage.Ecto do
    @moduledoc """
    The Ecto `StatifierPersistence.Storage.Adapter`: the storage contract
    over the schemas a host generates with `use StatifierPersistence.Ecto`
    (ADR-0002), against the tables the versioned migrations helper
    creates. Requires the optional `ecto_sql` dependency (ADR-0005).

        defmodule MyApp.Persistence do
          use StatifierPersistence.Ecto, repo: MyApp.Repo
        end

        {:ok, store} =
          StatifierPersistence.Storage.new(
            StatifierPersistence.Storage.Ecto,
            persistence: MyApp.Persistence
          )

    Options `init/1` accepts:

      * `:persistence` - required, a module that called
        `use StatifierPersistence.Ecto`. The repo, the schema modules,
        and the table names all come from its resolved configuration,
        so this adapter adds no knobs of its own (ADR-0002 decision 3).
      * `:sandbox` - when `true`, `isolate/1` checks out an
        `Ecto.Adapters.SQL.Sandbox` connection: the hook a test suite
        (this package's conformance suite included) uses to wrap each
        test in its own transaction. Default `false`, and `isolate/1`
        is then a no-op.

    Engine identities (`content_hash`, `session_id`, `run_id`) are
    stored verbatim in `text` columns and blobs in `bytea` columns, so
    both round-trip byte-identically (ADR-0002 decision 1, ADR-0003
    decision 1). The identity guard lives in
    `StatifierPersistence.Storage`, above this adapter like above every
    other one (ADR-0003 decision 2); nothing here decodes a blob.

    `insert_run/2`'s `:run_exists` refusal rides the V01 unique index on
    `run_id` - one atomic insert, never a check-then-insert. A backend
    failure a callback cannot observe as a value (the database down, a
    timeout) raises the driver's own exception rather than being
    flattened into a default (this package's errors-are-events rule).
    """

    @behaviour StatifierPersistence.Storage.Adapter

    import Ecto.Query, only: [from: 2]

    alias Ecto.Adapters.SQL.Sandbox
    alias Ecto.Changeset
    alias StatifierPersistence.Ecto.Config
    alias StatifierPersistence.Storage.Adapter

    # The runs.status column vocabulary (ADR-0004 decision 2), mapped
    # explicitly in both directions - never String.to_atom on database
    # bytes, and an unknown stored status fails loudly on a clause.
    @statuses [active: "active", completed: "completed", failed: "failed"]

    @doc """
    Resolves the `:persistence` host module into the handle every other
    callback takes: the host's repo, its three generated schema modules,
    and its runs table name (for the unique-constraint mapping).

    Refuses a module that never called `use StatifierPersistence.Ecto`
    with `{:error, {:adapter, {:not_a_persistence_host, module}}}`.
    Makes no database call: reachability surfaces on first use, per
    call site.
    """
    @impl Adapter
    @spec init(Adapter.opts()) :: {:ok, Adapter.opts()} | {:error, Adapter.error()}
    def init(opts) do
      host = Keyword.get(opts, :persistence)

      if persistence_host?(host) do
        config = host.__statifier_persistence__(:config)

        {:ok,
         Keyword.merge(opts,
           repo: config.repo,
           chart_schema: Module.concat(host, Chart),
           position_schema: Module.concat(host, Position),
           run_schema: Module.concat(host, Run),
           runs_table: Config.table(config, :runs)
         )}
      else
        {:error, {:adapter, {:not_a_persistence_host, host}}}
      end
    end

    @doc """
    Stores `chart_record`, idempotent on its `content_hash`: an insert
    with `on_conflict: :nothing` against the unique index, so a repeated
    save of the same hash neither duplicates the row nor rewrites it.
    """
    @impl Adapter
    @spec save_chart(Adapter.opts(), Adapter.chart_record()) :: :ok | {:error, Adapter.error()}
    def save_chart(opts, chart_record) do
      {:ok, _row} =
        repo(opts).insert(struct(chart_schema(opts), chart_record),
          on_conflict: :nothing,
          conflict_target: [:content_hash]
        )

      :ok
    end

    @doc """
    Fetches the chart stored under `content_hash`, or `:chart_not_found`.
    """
    @impl Adapter
    @spec fetch_chart(Adapter.opts(), Adapter.content_hash()) ::
            {:ok, Adapter.chart_record()} | {:error, Adapter.error()}
    def fetch_chart(opts, content_hash) do
      case repo(opts).get_by(chart_schema(opts), content_hash: content_hash) do
        nil ->
          {:error, :chart_not_found}

        row ->
          {:ok,
           %{
             content_hash: row.content_hash,
             identity_blob: row.identity_blob,
             chart_blob: row.chart_blob
           }}
      end
    end

    @doc """
    Stores `position_record` under its `session_id`, overwriting any
    position already stored for that session: an upsert replacing the
    record columns (and `updated_at`) on the unique index.
    """
    @impl Adapter
    @spec save_position(Adapter.opts(), Adapter.position_record()) ::
            :ok | {:error, Adapter.error()}
    def save_position(opts, position_record) do
      {:ok, _row} =
        repo(opts).insert(struct(position_schema(opts), position_record),
          on_conflict: {:replace, [:content_hash, :identity_blob, :position_blob, :updated_at]},
          conflict_target: [:session_id]
        )

      :ok
    end

    @doc """
    Fetches the position stored for `session_id`, or
    `:position_not_found`.
    """
    @impl Adapter
    @spec fetch_position(Adapter.opts(), Adapter.session_id()) ::
            {:ok, Adapter.position_record()} | {:error, Adapter.error()}
    def fetch_position(opts, session_id) do
      case repo(opts).get_by(position_schema(opts), session_id: session_id) do
        nil ->
          {:error, :position_not_found}

        row ->
          {:ok,
           %{
             session_id: row.session_id,
             content_hash: row.content_hash,
             identity_blob: row.identity_blob,
             position_blob: row.position_blob
           }}
      end
    end

    @doc """
    Inserts `run_record`, refusing a duplicate `run_id` with
    `{:error, :run_exists}`.

    The refusal is the V01 unique index on `run_id` speaking: the insert
    carries a `unique_constraint/3` on that index's name, so two
    concurrent inserts of one `run_id` cannot both return `:ok` and no
    separate existence check ever runs.
    """
    @impl Adapter
    @spec insert_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
    def insert_run(opts, run_record) do
      row = struct(run_schema(opts), %{run_record | status: encode_status(run_record.status)})

      changeset =
        row
        |> Changeset.change()
        |> Changeset.unique_constraint(:run_id,
          name: "#{Keyword.fetch!(opts, :runs_table)}_run_id_index"
        )

      case repo(opts).insert(changeset) do
        {:ok, _row} -> :ok
        {:error, %Changeset{}} -> {:error, :run_exists}
      end
    end

    @doc """
    Fetches the run stored under `run_id`, or `:run_not_found`.
    """
    @impl Adapter
    @spec fetch_run(Adapter.opts(), Adapter.run_id()) ::
            {:ok, Adapter.run_record()} | {:error, Adapter.error()}
    def fetch_run(opts, run_id) do
      case repo(opts).get_by(run_schema(opts), run_id: run_id) do
        nil ->
          {:error, :run_not_found}

        row ->
          {:ok,
           %{
             run_id: row.run_id,
             status: decode_status(row.status),
             content_hash: row.content_hash,
             identity_blob: row.identity_blob,
             position_blob: row.position_blob,
             failure: row.failure
           }}
      end
    end

    @doc """
    Overwrites the run stored under `run_record`'s `run_id` with the
    full record, or refuses with `:run_not_found`.

    One `update_all/3` keyed on `run_id`: the match count is the
    existence check, so refusal and overwrite are a single statement.
    """
    @impl Adapter
    @spec update_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
    def update_run(opts, %{run_id: run_id} = run_record) do
      query = from(r in run_schema(opts), where: r.run_id == ^run_id)

      updates = [
        status: encode_status(run_record.status),
        content_hash: run_record.content_hash,
        identity_blob: run_record.identity_blob,
        position_blob: run_record.position_blob,
        failure: run_record.failure,
        updated_at: DateTime.utc_now()
      ]

      case repo(opts).update_all(query, set: updates) do
        {1, _returned} -> :ok
        {0, _returned} -> {:error, :run_not_found}
      end
    end

    @doc """
    Per-test isolation (the optional
    `c:StatifierPersistence.Storage.Adapter.isolate/1`): checks out an
    `Ecto.Adapters.SQL.Sandbox` connection when this handle was built
    with `sandbox: true`, and is a no-op otherwise.
    """
    @impl Adapter
    @spec isolate(Adapter.opts()) :: :ok | {:error, Adapter.error()}
    def isolate(opts) do
      if Keyword.get(opts, :sandbox, false) do
        case Sandbox.checkout(repo(opts)) do
          :ok -> :ok
          {:already, _owner_or_allowed} -> :ok
        end
      else
        :ok
      end
    end

    @spec repo(Adapter.opts()) :: module()
    defp repo(opts), do: Keyword.fetch!(opts, :repo)

    @spec chart_schema(Adapter.opts()) :: module()
    defp chart_schema(opts), do: Keyword.fetch!(opts, :chart_schema)

    @spec position_schema(Adapter.opts()) :: module()
    defp position_schema(opts), do: Keyword.fetch!(opts, :position_schema)

    @spec run_schema(Adapter.opts()) :: module()
    defp run_schema(opts), do: Keyword.fetch!(opts, :run_schema)

    @spec persistence_host?(term()) :: boolean()
    defp persistence_host?(host) do
      is_atom(host) and not is_nil(host) and Code.ensure_loaded?(host) and
        function_exported?(host, :__statifier_persistence__, 1)
    end

    for {atom, string} <- @statuses do
      defp encode_status(unquote(atom)), do: unquote(string)
      defp decode_status(unquote(string)), do: unquote(atom)
    end
  end
end
