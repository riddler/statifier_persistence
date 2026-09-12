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
      * `:input_log_cap` - the per-execution cap on ADR-0010's input log:
        `:infinity` (the default, no cap) or a positive integer. It
        counts entries, and past it `append_input/3` refuses and closes
        the execution's log with a marker (decision 6). It has no bounded
        default, because one would be this package silently truncating a
        host's log.
      * `:sandbox` - when `true`, `isolate/1` checks out an
        `Ecto.Adapters.SQL.Sandbox` connection: the hook a test suite
        (this package's conformance suite included) uses to wrap each
        test in its own transaction. Default `false`, and `isolate/1`
        is then a no-op.

    Engine identities (`content_hash`, `session_id`, `execution_id`) are
    stored verbatim in `text` columns and blobs in `bytea` columns, so
    both round-trip byte-identically (ADR-0002 decision 1, ADR-0003
    decision 1). The identity guard lives in
    `StatifierPersistence.Storage`, above this adapter like above every
    other one (ADR-0003 decision 2); nothing here decodes a blob.

    `insert_execution/2`'s `:execution_exists` refusal rides the V01 unique index on
    `execution_id` - one atomic insert, never a check-then-insert. A backend
    failure a callback cannot observe as a value (the database down, a
    timeout) raises the driver's own exception rather than being
    flattened into a default (this package's errors-are-events rule).
    """

    @behaviour StatifierPersistence.Storage.Adapter

    import Ecto.Query, only: [from: 2]

    alias Ecto.Adapters.SQL.Sandbox
    alias Ecto.Changeset
    alias StatifierPersistence.Ecto.Config
    alias StatifierPersistence.Execution.Linkage
    alias StatifierPersistence.Storage.Adapter

    # The executions.status column vocabulary (ADR-0004 decision 2), mapped
    # explicitly in both directions - never String.to_atom on database
    # bytes, and an unknown stored status fails loudly on a clause.
    @statuses [active: "active", completed: "completed", failed: "failed", cancelled: "cancelled"]

    @doc """
    Resolves the `:persistence` host module into the handle every other
    callback takes: the host's repo, its three generated schema modules,
    and its executions table name (for the unique-constraint mapping).

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
        cap = validate_cap!(Keyword.get(opts, :input_log_cap, :infinity))

        {:ok,
         Keyword.merge(opts,
           repo: config.repo,
           chart_schema: Module.concat(host, Chart),
           position_schema: Module.concat(host, Position),
           execution_schema: Module.concat(host, Execution),
           input_schema: Module.concat(host, Input),
           runs_table: Config.table(config, :runs),
           inputs_table: Config.table(config, :inputs),
           input_log_cap: cap
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
    Inserts `execution_record`, refusing a duplicate `execution_id` with
    `{:error, :execution_exists}`.

    The refusal is the V01 unique index on `execution_id` speaking: the insert
    carries a `unique_constraint/3` on that index's name, so two
    concurrent inserts of one `execution_id` cannot both return `:ok` and no
    separate existence check ever executions.

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
    @spec insert_execution(Adapter.opts(), Adapter.execution_record()) ::
            :ok | {:error, Adapter.error()}
    def insert_execution(opts, execution_record) do
      metadata = Map.get(execution_record, :metadata, %{})

      if json_representable?(metadata) do
        do_insert_execution(opts, execution_record, metadata)
      else
        {:error, :metadata_unsupported}
      end
    end

    @spec do_insert_execution(Adapter.opts(), Adapter.execution_record(), Adapter.metadata()) ::
            :ok | {:error, Adapter.error()}
    defp do_insert_execution(opts, execution_record, metadata) do
      row =
        struct(
          execution_schema(opts),
          Map.merge(execution_record, %{
            status: encode_status(execution_record.status),
            metadata: encode_metadata(metadata)
          })
        )

      changeset =
        row
        |> Changeset.change()
        |> Changeset.unique_constraint(:execution_id,
          # The index name is DDL, not API: V01 created it and V06 (sp-j2y)
          # renames it with the table and the column.
          name: "#{Keyword.fetch!(opts, :runs_table)}_run_id_index"
        )

      case repo(opts).insert(changeset) do
        {:ok, _row} -> :ok
        {:error, %Changeset{}} -> {:error, :execution_exists}
      end
    end

    @doc """
    Fetches the execution stored under `execution_id`, or `:execution_not_found`.
    """
    @impl Adapter
    @spec fetch_execution(Adapter.opts(), Adapter.execution_id()) ::
            {:ok, Adapter.execution_record()} | {:error, Adapter.error()}
    def fetch_execution(opts, execution_id) do
      case repo(opts).get_by(execution_schema(opts), execution_id: execution_id) do
        nil ->
          {:error, :execution_not_found}

        row ->
          {:ok, to_execution_record(row)}
      end
    end

    @doc """
    Overwrites the execution stored under `execution_record`'s `execution_id` with the
    full record, or refuses with `:execution_not_found`.

    One `update_all/3` keyed on `execution_id`: the match count is the
    existence check, so refusal and overwrite are a single statement.

    `metadata` is not in the `set:` list, and that is the documented
    exception to the full overwrite: the map is write-once (ADR-0006
    decision 1 grants it at create and grants no way to change it), so the
    stored column is left exactly as `insert_execution/2` wrote it and the given
    record's `metadata` is ignored.

    `outcome_blob` is the second exception, and it joins the `set:` list
    only when the given record carries one: a `nil` leaves the stored
    column alone, so an ordinary step of an execution that has already answered
    does not erase its answer.
    """
    @impl Adapter
    @spec update_execution(Adapter.opts(), Adapter.execution_record()) ::
            :ok | {:error, Adapter.error()}
    def update_execution(opts, %{execution_id: execution_id} = execution_record) do
      query = from(r in execution_schema(opts), where: r.execution_id == ^execution_id)

      updates =
        [
          status: encode_status(execution_record.status),
          content_hash: execution_record.content_hash,
          identity_blob: execution_record.identity_blob,
          position_blob: execution_record.position_blob,
          failure: execution_record.failure,
          updated_at: DateTime.utc_now()
        ] ++ outcome_update(Map.get(execution_record, :outcome_blob))

      case repo(opts).update_all(query, set: updates) do
        {1, _returned} -> :ok
        {0, _returned} -> {:error, :execution_not_found}
      end
    end

    @spec outcome_update(binary() | nil) :: keyword()
    defp outcome_update(nil), do: []
    defp outcome_update(outcome_blob), do: [outcome_blob: outcome_blob]

    @doc """
    Declares outcome support (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_execution_outcome?/1`):
    this adapter stores an execution's answer in the V03 `outcome_blob` column,
    under the configured `:blob_type` like every other blob column.
    """
    @impl Adapter
    @spec supports_execution_outcome?(Adapter.opts()) :: boolean()
    def supports_execution_outcome?(_opts), do: true

    @doc """
    The indexed status projection over a metadata match (the optional
    `c:StatifierPersistence.Storage.Adapter.list_execution_states_by_metadata/2`).

    The same `jsonb` containment predicate `list_executions_by_metadata/2`
    issues - which V03's GIN `jsonb_path_ops` index serves - with a
    three-column `select:` in place of the whole row. No blob column is
    read, which is the point: a fan-out of N children asks this question N
    times, and the listing would move N identity and position blobs each
    time.

    `child_index` is extracted from this package's own reserved linkage
    namespace inside `metadata`, and is `nil` for a matched execution carrying
    no linkage.

    Takes the same non-empty string-keyed map, with the same
    `ArgumentError` for anything else.

    Off Postgres this refuses with `{:error, :metadata_unsupported}`
    rather than issuing SQL the backend cannot parse - the same answer
    `supports_metadata?/1` already gives the facade, given directly to a
    caller who reached the callback itself.
    """
    @impl Adapter
    @spec list_execution_states_by_metadata(Adapter.opts(), Adapter.metadata()) ::
            {:ok, [Adapter.execution_state()]} | {:error, Adapter.error()}
    def list_execution_states_by_metadata(opts, metadata) do
      validate_match!(metadata)

      if supports_metadata?(opts) and json_representable?(metadata) do
        reserved = Linkage.reserved_key()

        rows =
          repo(opts).all(
            from(r in execution_schema(opts),
              where: fragment("? @> ?", r.metadata, type(^metadata, :map)),
              select: %{
                execution_id: r.execution_id,
                status: r.status,
                child_index: fragment("? -> ? ->> 'child_index'", r.metadata, ^reserved)
              }
            )
          )

        {:ok, Enum.map(rows, &to_execution_state/1)}
      else
        {:error, :metadata_unsupported}
      end
    end

    @spec to_execution_state(map()) :: Adapter.execution_state()
    defp to_execution_state(row) do
      %{
        execution_id: row.execution_id,
        status: decode_status(row.status),
        child_index: decode_child_index(row.child_index)
      }
    end

    # `->>` yields text or NULL, never an integer, so the index comes back
    # as a string for a linked execution and `nil` for one with no linkage.
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
    adapter stores an execution's metadata in the V02 `jsonb` column (ADR-0006
    decision 3), **on a Postgres repo**.

    On any other Ecto adapter this answers `false`, which is ADR-0006
    decision 3's refusal-at-open arm rather than a new one. The capability
    that record defines is the column *and* the equality-match list
    helper, and the helper is Postgres-only SQL: both
    `list_executions_by_metadata/2` and `list_execution_states_by_metadata/2` are
    `jsonb` containment (`@>`) with a `-> ... ->>` extraction, which a
    non-Postgres backend does not parse. Declaring the capability true
    there would strand a durable subchart or a fan-out at the far end of
    a listing that cannot answer, with children already started that
    nothing could then settle (sp-11w).

    The two listings consult this answer themselves, so a caller holding
    the raw callback gets the same `{:error, :metadata_unsupported}` the
    facade gives rather than a raise from the driver (sp-4eo). V03's
    `metadata` index is skipped on the same adapters, for the same
    reason; sp-5lm tracks this surface.
    """
    @impl Adapter
    @spec supports_metadata?(Adapter.opts()) :: boolean()
    def supports_metadata?(opts), do: repo(opts).__adapter__() == Ecto.Adapters.Postgres

    @doc """
    Lists the executions whose stored `metadata` contains **every** key/value
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
    "contains every given pair" matches every execution with any metadata at
    all, which is a caller bug far more often than a request, so it
    raises `ArgumentError` rather than answering it.

        StatifierPersistence.Storage.Ecto.list_executions_by_metadata(
          store.opts,
          %{"tenant_id" => "acct_01H8X"}
        )

    Returns records in `fetch_execution/2`'s shape.

    Off Postgres this refuses with `{:error, :metadata_unsupported}`
    rather than issuing SQL the backend cannot parse - the same answer
    `supports_metadata?/1` already gives the facade, given directly to a
    caller who reached the callback itself.
    """
    @impl Adapter
    @spec list_executions_by_metadata(Adapter.opts(), Adapter.metadata()) ::
            {:ok, [Adapter.execution_record()]} | {:error, Adapter.error()}
    def list_executions_by_metadata(opts, metadata) do
      validate_match!(metadata)

      if supports_metadata?(opts) and json_representable?(metadata) do
        rows =
          repo(opts).all(
            from(r in execution_schema(opts),
              where: fragment("? @> ?", r.metadata, type(^metadata, :map))
            )
          )

        {:ok, Enum.map(rows, &to_execution_record/1)}
      else
        {:error, :metadata_unsupported}
      end
    end

    @doc """
    Declares input log support (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_input_log?/1`): this
    adapter keeps ADR-0010's log in the V05 inputs table, on every Ecto
    backend.

    Unconditional, unlike `supports_metadata?/1`, which answers `false`
    off Postgres because the containment SQL its listings issue does not
    parse there. Nothing in the input log needs a Postgres-only feature -
    a table, four columns and a unique index (ADR-0010 decision 9) - so
    there is nothing here for a backend to decline.
    """
    @impl Adapter
    @spec supports_input_log?(Adapter.opts()) :: boolean()
    def supports_input_log?(_opts), do: true

    @doc """
    Appends one input at the execution's next ordinal (the optional
    `c:StatifierPersistence.Storage.Adapter.append_input/3`).

    The ordinal is the execution's current maximum plus one, read and written
    inside the exclusion the caller already holds
    (`StatifierPersistence.Executions`' serialized unit). The V05 unique index
    on `(execution_id, seq)`, not the read, is what makes denseness true: a
    lost race fails the write with `{:adapter, :seq_conflict}` rather
    than duplicating an ordinal.

    Past the configured `input_log_cap:` the log closes itself. The cap's
    last slot is written as a row with a `nil` `input_blob` - decision
    6's marker - and this call and every later one for that execution return
    `{:error, :input_log_full}`. The step that produced the input is not
    failed by it: the log records its own truncation instead
    (ADR-0010 decision 5).
    """
    @impl Adapter
    @spec append_input(Adapter.opts(), Adapter.execution_id(), Adapter.input_record()) ::
            {:ok, Adapter.seq()} | {:error, Adapter.error()}
    def append_input(opts, execution_id, %{door: door, input_blob: input_blob}) do
      case next_slot(opts, execution_id) do
        {:closed, _seq} ->
          {:error, :input_log_full}

        {:marker, seq} ->
          with :ok <- insert_input(opts, execution_id, seq, door, nil),
               do: {:error, :input_log_full}

        {:open, seq} ->
          with :ok <- insert_input(opts, execution_id, seq, door, input_blob), do: {:ok, seq}
      end
    end

    @doc """
    Lists an execution's whole log in ascending `seq` (the optional
    `c:StatifierPersistence.Storage.Adapter.list_inputs/2`), or
    `:execution_not_found` for an execution this adapter does not hold.

    One index-ordered read of the V05 unique index. No filter, no range,
    no limit: the whole log is what a replay consumes and the cap is what
    bounds it (ADR-0010 decision 2).
    """
    @impl Adapter
    @spec list_inputs(Adapter.opts(), Adapter.execution_id()) ::
            {:ok, [Adapter.input_record()]} | {:error, Adapter.error()}
    def list_inputs(opts, execution_id) do
      if execution_exists?(opts, execution_id) do
        {:ok, Enum.map(input_rows(opts, execution_id), &to_input_record/1)}
      else
        {:error, :execution_not_found}
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
    Executions `fun` under per-execution mutual exclusion for `execution_id` (the optional
    `c:StatifierPersistence.Storage.Adapter.lock_execution/3`, ADR-0004
    decision 5 as amended 2026-08-22).

    Everything happens inside one transaction that spans `fun`. It takes
    `pg_advisory_xact_lock(hashtextextended(execution_id, 0))` first -
    unconditional per-execution exclusion whether or not the execution row exists
    yet - and then `SELECT ... FOR UPDATE` on the execution row when it does,
    keeping the row itself locked against every other writer for the
    rest of the transaction. Both locks are transaction-scoped, so any
    exit from `fun` releases them: a normal return commits, and a raise
    rolls back and propagates to the caller with nothing leaked.
    """
    @impl Adapter
    @spec lock_execution(Adapter.opts(), Adapter.execution_id(), (-> result)) ::
            {:ok, result} | {:error, Adapter.error()}
          when result: term()
    def lock_execution(opts, execution_id, fun) do
      repo = repo(opts)
      schema = execution_schema(opts)

      transaction =
        repo.transaction(fn ->
          %{rows: [[_void]]} =
            repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [
              execution_id
            ])

          _row_locked =
            repo.all(
              from(r in schema,
                where: r.execution_id == ^execution_id,
                select: r.id,
                lock: "FOR UPDATE"
              )
            )

          fun.()
        end)

      case transaction do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {:adapter, reason}}
      end
    end

    @spec to_execution_record(struct()) :: Adapter.execution_record()
    defp to_execution_record(row) do
      %{
        execution_id: row.execution_id,
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
              "list_executions_by_metadata/2 takes a map with string keys, got keys: " <>
                inspect(Map.keys(metadata))
      end
    end

    defp validate_match!(other) do
      raise ArgumentError,
            "list_executions_by_metadata/2 takes a non-empty map with string keys, " <>
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

    # The three states the next append can be in: the log already carries
    # a closed marker in its last slot, this append IS the last slot the
    # cap admits, or there is room. One read of the tail row answers all
    # three, since seq is dense.
    @spec next_slot(Adapter.opts(), Adapter.execution_id()) ::
            {:closed | :marker | :open, Adapter.seq()}
    defp next_slot(opts, execution_id) do
      cap = Keyword.fetch!(opts, :input_log_cap)

      last =
        repo(opts).one(
          from(i in input_schema(opts),
            where: i.execution_id == ^execution_id,
            order_by: [desc: i.seq],
            limit: 1,
            select: %{seq: i.seq, input_blob: i.input_blob}
          )
        )

      seq =
        case last do
          nil -> 0
          %{seq: seq} -> seq + 1
        end

      cond do
        match?(%{input_blob: nil}, last) -> {:closed, seq}
        cap == :infinity -> {:open, seq}
        seq >= cap - 1 -> {:marker, seq}
        true -> {:open, seq}
      end
    end

    @spec insert_input(
            Adapter.opts(),
            Adapter.execution_id(),
            Adapter.seq(),
            Adapter.door(),
            binary() | nil
          ) :: :ok | {:error, Adapter.error()}
    defp insert_input(opts, execution_id, seq, door, input_blob) do
      changeset =
        input_schema(opts)
        |> struct(%{execution_id: execution_id, seq: seq, door: door, input_blob: input_blob})
        |> Changeset.change()
        |> Changeset.unique_constraint([:execution_id, :seq],
          # DDL again: V05 created this name and V06 (sp-j2y) renames it.
          name: "#{Keyword.fetch!(opts, :inputs_table)}_run_id_seq_index"
        )

      case repo(opts).insert(changeset) do
        {:ok, _row} -> :ok
        {:error, %Changeset{}} -> {:error, {:adapter, :seq_conflict}}
      end
    end

    @spec input_rows(Adapter.opts(), Adapter.execution_id()) :: [map()]
    defp input_rows(opts, execution_id) do
      repo(opts).all(
        from(i in input_schema(opts),
          where: i.execution_id == ^execution_id,
          order_by: [asc: i.seq],
          select: %{
            execution_id: i.execution_id,
            seq: i.seq,
            door: i.door,
            input_blob: i.input_blob
          }
        )
      )
    end

    @spec execution_exists?(Adapter.opts(), Adapter.execution_id()) :: boolean()
    defp execution_exists?(opts, execution_id) do
      repo(opts).exists?(
        from(r in execution_schema(opts), where: r.execution_id == ^execution_id)
      )
    end

    @spec to_input_record(map()) :: Adapter.input_record()
    defp to_input_record(row) do
      %{execution_id: row.execution_id, seq: row.seq, door: row.door, input_blob: row.input_blob}
    end

    @spec validate_cap!(term()) :: pos_integer() | :infinity
    defp validate_cap!(:infinity), do: :infinity
    defp validate_cap!(cap) when is_integer(cap) and cap > 0, do: cap

    defp validate_cap!(other) do
      raise ArgumentError,
            "the :input_log_cap option must be a positive integer or :infinity, " <>
              "got: #{inspect(other)}"
    end

    @spec repo(Adapter.opts()) :: module()
    defp repo(opts), do: Keyword.fetch!(opts, :repo)

    @spec chart_schema(Adapter.opts()) :: module()
    defp chart_schema(opts), do: Keyword.fetch!(opts, :chart_schema)

    @spec position_schema(Adapter.opts()) :: module()
    defp position_schema(opts), do: Keyword.fetch!(opts, :position_schema)

    @spec execution_schema(Adapter.opts()) :: module()
    defp execution_schema(opts), do: Keyword.fetch!(opts, :execution_schema)

    @spec input_schema(Adapter.opts()) :: module()
    defp input_schema(opts), do: Keyword.fetch!(opts, :input_schema)

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
