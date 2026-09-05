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
    alias StatifierPersistence.Run.Linkage
    alias StatifierPersistence.Storage.Adapter

    # The runs.status column vocabulary (ADR-0004 decision 2), mapped
    # explicitly in both directions - never String.to_atom on database
    # bytes, and an unknown stored status fails loudly on a clause.
    @statuses [active: "active", completed: "completed", failed: "failed", cancelled: "cancelled"]

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

    `metadata` is stored in the V02 `jsonb` column, `NULL` for the empty
    map. `jsonb` holds only JSON-representable values, which makes `term`
    narrower here than in Elixir (ADR-0006 decision 3): a tuple, a pid, a
    reference, an atom, a struct, or a binary that is not valid UTF-8 has
    no `jsonb` form. This adapter refuses such a map at open with
    `{:error, :metadata_unsupported}` - the failure shape ADR-0006
    decision 3 leaves to the implementation - rather than letting the
    encoder raise from inside a transaction or, worse, storing something
    that is not what the caller handed over. Refusing at open is the
    principle the decision already sets for an adapter that cannot store a
    map; a value it cannot store is the same answer at a finer grain.
    """
    @impl Adapter
    @spec insert_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
    def insert_run(opts, run_record) do
      metadata = Map.get(run_record, :metadata, %{})

      if json_representable?(metadata) do
        do_insert_run(opts, run_record, metadata)
      else
        {:error, :metadata_unsupported}
      end
    end

    @spec do_insert_run(Adapter.opts(), Adapter.run_record(), Adapter.metadata()) ::
            :ok | {:error, Adapter.error()}
    defp do_insert_run(opts, run_record, metadata) do
      row =
        struct(
          run_schema(opts),
          Map.merge(run_record, %{
            status: encode_status(run_record.status),
            metadata: encode_metadata(metadata)
          })
        )

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
          {:ok, to_run_record(row)}
      end
    end

    @doc """
    Overwrites the run stored under `run_record`'s `run_id` with the
    full record, or refuses with `:run_not_found`.

    One `update_all/3` keyed on `run_id`: the match count is the
    existence check, so refusal and overwrite are a single statement.

    `metadata` is not in the `set:` list, and that is the documented
    exception to the full overwrite: the map is write-once (ADR-0006
    decision 1 grants it at create and grants no way to change it), so the
    stored column is left exactly as `insert_run/2` wrote it and the given
    record's `metadata` is ignored.

    `outcome_blob` is the second exception, and it joins the `set:` list
    only when the given record carries one: a `nil` leaves the stored
    column alone, so an ordinary step of a run that has already answered
    does not erase its answer.
    """
    @impl Adapter
    @spec update_run(Adapter.opts(), Adapter.run_record()) :: :ok | {:error, Adapter.error()}
    def update_run(opts, %{run_id: run_id} = run_record) do
      query = from(r in run_schema(opts), where: r.run_id == ^run_id)

      updates =
        [
          status: encode_status(run_record.status),
          content_hash: run_record.content_hash,
          identity_blob: run_record.identity_blob,
          position_blob: run_record.position_blob,
          failure: run_record.failure,
          updated_at: DateTime.utc_now()
        ] ++ outcome_update(Map.get(run_record, :outcome_blob))

      case repo(opts).update_all(query, set: updates) do
        {1, _returned} -> :ok
        {0, _returned} -> {:error, :run_not_found}
      end
    end

    @spec outcome_update(binary() | nil) :: keyword()
    defp outcome_update(nil), do: []
    defp outcome_update(outcome_blob), do: [outcome_blob: outcome_blob]

    @doc """
    Declares outcome support (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_run_outcome?/1`):
    this adapter stores a run's answer in the V03 `outcome_blob` column,
    under the configured `:blob_type` like every other blob column.
    """
    @impl Adapter
    @spec supports_run_outcome?(Adapter.opts()) :: boolean()
    def supports_run_outcome?(_opts), do: true

    @doc """
    The indexed status projection over a metadata match (the optional
    `c:StatifierPersistence.Storage.Adapter.list_run_states_by_metadata/2`).

    The same `jsonb` containment predicate `list_runs_by_metadata/2`
    issues - which V03's GIN `jsonb_path_ops` index serves - with a
    three-column `select:` in place of the whole row. No blob column is
    read, which is the point: a fan-out of N children asks this question N
    times, and the listing would move N identity and position blobs each
    time.

    `child_index` is extracted from this package's own reserved linkage
    namespace inside `metadata`, and is `nil` for a matched run carrying
    no linkage.

    Takes the same non-empty string-keyed map, with the same
    `ArgumentError` for anything else.
    """
    @impl Adapter
    @spec list_run_states_by_metadata(Adapter.opts(), Adapter.metadata()) ::
            {:ok, [Adapter.run_state()]} | {:error, Adapter.error()}
    def list_run_states_by_metadata(opts, metadata) do
      validate_match!(metadata)

      if json_representable?(metadata) do
        reserved = Linkage.reserved_key()

        rows =
          repo(opts).all(
            from(r in run_schema(opts),
              where: fragment("? @> ?", r.metadata, type(^metadata, :map)),
              select: %{
                run_id: r.run_id,
                status: r.status,
                child_index: fragment("? -> ? ->> 'child_index'", r.metadata, ^reserved)
              }
            )
          )

        {:ok, Enum.map(rows, &to_run_state/1)}
      else
        {:error, :metadata_unsupported}
      end
    end

    @spec to_run_state(map()) :: Adapter.run_state()
    defp to_run_state(row) do
      %{
        run_id: row.run_id,
        status: decode_status(row.status),
        child_index: decode_child_index(row.child_index)
      }
    end

    # `->>` yields text or NULL, never an integer, so the index comes back
    # as a string for a linked run and `nil` for one with no linkage.
    @spec decode_child_index(String.t() | nil) :: non_neg_integer() | nil
    defp decode_child_index(nil), do: nil

    defp decode_child_index(index) when is_binary(index) do
      case Integer.parse(index) do
        {parsed, ""} -> parsed
        _not_an_integer -> nil
      end
    end

    @doc """
    Declares metadata support (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_metadata?/1`): this
    adapter stores a run's metadata in the V02 `jsonb` column (ADR-0006
    decision 3).
    """
    @impl Adapter
    @spec supports_metadata?(Adapter.opts()) :: boolean()
    def supports_metadata?(_opts), do: true

    @doc """
    Lists the runs whose stored `metadata` contains **every** key/value
    pair in `metadata` (ADR-0006 decision 3's equality-match list helper).

    Equality match on all pairs is the whole query surface: no ranges, no
    partial matches, no containment operators exposed to the caller, and
    no ordering guarantee. A host needing more than that queries its own
    column directly - ADR-0002's configurable table names already make
    that a supported thing to do.

    The query is one `jsonb` containment predicate, which a GIN index on
    the column serves directly; V02 ships no index, because which pairs a
    host queries by is the host's call (ADR-0006 decision 4).

    `metadata` must be a non-empty map of string keys: a zero-pair
    "contains every given pair" matches every run with any metadata at
    all, which is a caller bug far more often than a request, so it
    raises `ArgumentError` rather than answering it.

        StatifierPersistence.Storage.Ecto.list_runs_by_metadata(
          store.opts,
          %{"tenant_id" => "acct_01H8X"}
        )

    Returns records in `fetch_run/2`'s shape.
    """
    @impl Adapter
    @spec list_runs_by_metadata(Adapter.opts(), Adapter.metadata()) ::
            {:ok, [Adapter.run_record()]} | {:error, Adapter.error()}
    def list_runs_by_metadata(opts, metadata) do
      validate_match!(metadata)

      if json_representable?(metadata) do
        rows =
          repo(opts).all(
            from(r in run_schema(opts),
              where: fragment("? @> ?", r.metadata, type(^metadata, :map))
            )
          )

        {:ok, Enum.map(rows, &to_run_record/1)}
      else
        {:error, :metadata_unsupported}
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

    @doc """
    Runs `fun` under per-run mutual exclusion for `run_id` (the optional
    `c:StatifierPersistence.Storage.Adapter.lock_run/3`, ADR-0004
    decision 5 as amended 2026-08-22).

    Everything happens inside one transaction that spans `fun`. It takes
    `pg_advisory_xact_lock(hashtextextended(run_id, 0))` first -
    unconditional per-run exclusion whether or not the run row exists
    yet - and then `SELECT ... FOR UPDATE` on the run row when it does,
    keeping the row itself locked against every other writer for the
    rest of the transaction. Both locks are transaction-scoped, so any
    exit from `fun` releases them: a normal return commits, and a raise
    rolls back and propagates to the caller with nothing leaked.
    """
    @impl Adapter
    @spec lock_run(Adapter.opts(), Adapter.run_id(), (-> result)) ::
            {:ok, result} | {:error, Adapter.error()}
          when result: term()
    def lock_run(opts, run_id, fun) do
      repo = repo(opts)
      schema = run_schema(opts)

      transaction =
        repo.transaction(fn ->
          %{rows: [[_void]]} =
            repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [run_id])

          _row_locked =
            repo.all(
              from(r in schema, where: r.run_id == ^run_id, select: r.id, lock: "FOR UPDATE")
            )

          fun.()
        end)

      case transaction do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {:adapter, reason}}
      end
    end

    @spec to_run_record(struct()) :: Adapter.run_record()
    defp to_run_record(row) do
      %{
        run_id: row.run_id,
        status: decode_status(row.status),
        content_hash: row.content_hash,
        identity_blob: row.identity_blob,
        position_blob: row.position_blob,
        failure: row.failure,
        metadata: row.metadata || %{},
        outcome_blob: row.outcome_blob
      }
    end

    # The empty map is stored as NULL: the column is nullable precisely so
    # "no metadata" needs no invented value (V02's moduledoc).
    @spec encode_metadata(Adapter.metadata()) :: map() | nil
    defp encode_metadata(metadata) when map_size(metadata) == 0, do: nil
    defp encode_metadata(metadata), do: metadata

    @spec validate_match!(term()) :: :ok
    defp validate_match!(metadata)
         when is_map(metadata) and map_size(metadata) > 0 do
      if Enum.all?(Map.keys(metadata), &is_binary/1) do
        :ok
      else
        raise ArgumentError,
              "list_runs_by_metadata/2 takes a map with string keys, got keys: " <>
                inspect(Map.keys(metadata))
      end
    end

    defp validate_match!(other) do
      raise ArgumentError,
            "list_runs_by_metadata/2 takes a non-empty map with string keys, " <>
              "got: #{inspect(other)}"
    end

    # What `jsonb` can hold, checked structurally rather than by attempting
    # an encode: string keys, and values drawn from JSON's own set. An atom
    # is deliberately not JSON-representable here even though most encoders
    # will stringify one - a value that comes back as a different term than
    # it went in is exactly the silent drop ADR-0006 decision 3 refuses.
    @spec json_representable?(term()) :: boolean()
    defp json_representable?(value)
         when is_binary(value),
         do: String.valid?(value)

    defp json_representable?(value) when is_number(value), do: true
    defp json_representable?(value) when is_boolean(value) or is_nil(value), do: true

    defp json_representable?(value) when is_list(value),
      do: Enum.all?(value, &json_representable?/1)

    defp json_representable?(value) when is_map(value) and not is_struct(value) do
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_representable?(item)
      end)
    end

    defp json_representable?(_other), do: false

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
