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

    import Ecto.Query, only: [exclude: 2, from: 2, subquery: 1]

    alias Ecto.Adapters.SQL.Sandbox
    alias Ecto.Changeset
    alias StatifierPersistence.Ecto.Config
    alias StatifierPersistence.Execution.Linkage
    alias StatifierPersistence.Storage.Adapter

    # The executions.status column vocabulary (ADR-0004 decision 2), mapped
    # explicitly in both directions - never String.to_atom on database
    # bytes, and an unknown stored status fails loudly on a clause. The
    # column has no constraint through V07, so `needs_migration` (ADR-0014
    # decisions 1 and 7) is a new string here and no schema version.
    @statuses [
      active: "active",
      needs_migration: "needs_migration",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled"
    ]

    # Every key of the drained query's answer at zero. The grouped count
    # returns only the arms the table holds rows in, so the answer is
    # folded onto this rather than built from what came back.
    @zero_counts %{
      active: 0,
      needs_migration: 0,
      completed: 0,
      failed: 0,
      cancelled: 0,
      children: 0
    }

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
           executions_table: Config.table(config, :executions),
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

    A tombstoned hash is refused with
    `{:error, {:chart_retired, info}}` and not revived (ADR-0012
    decision 6). What keeps a tombstoned row from being revived is the
    unique index, not the read: the insert never rewrites an existing
    row, so no interleaving puts the bytes back. The read is what turns
    a save of a retired hash into the retired arm rather than a silent
    `:ok`, and it answers for the row as it stood when it ran. The read
    and the insert are one transaction, but under Postgres's default
    READ COMMITTED each statement reads its own snapshot, so a
    retirement committing between the two leaves this save answering
    `:ok` - which is the answer the save would have had in the order it
    was read in, a save followed by a retirement, and the row stays
    tombstoned. The transaction joins a caller's own when there is one,
    which is what keeps the README's "Writing inside a caller's
    transaction" contract intact.
    """
    @impl Adapter
    @spec save_chart(Adapter.opts(), Adapter.chart_record()) :: :ok | {:error, Adapter.error()}
    def save_chart(opts, chart_record) do
      {:ok, answer} =
        repo(opts).transaction(fn ->
          case retired_info(opts, chart_record.content_hash) do
            nil -> insert_chart(opts, chart_record)
            info -> {:error, {:chart_retired, info}}
          end
        end)

      answer
    end

    @spec insert_chart(Adapter.opts(), Adapter.chart_record()) :: :ok
    defp insert_chart(opts, chart_record) do
      {:ok, _row} =
        repo(opts).insert(struct(chart_schema(opts), chart_record),
          on_conflict: :nothing,
          conflict_target: [:content_hash]
        )

      :ok
    end

    @doc """
    Fetches the chart stored under `content_hash`, or `:chart_not_found`.

    A tombstoned hash answers `{:error, {:chart_retired, info}}` instead,
    carrying who retired it and when (ADR-0012 decision 6): the row is
    still there and its blobs are `nil`, and a record with `nil` blobs is
    not a chart this adapter holds.
    """
    @impl Adapter
    @spec fetch_chart(Adapter.opts(), Adapter.content_hash()) ::
            {:ok, Adapter.chart_record()} | {:error, Adapter.error()}
    def fetch_chart(opts, content_hash) do
      case repo(opts).get_by(chart_schema(opts), content_hash: content_hash) do
        nil ->
          {:error, :chart_not_found}

        %{retired_at: retired_at} = row when not is_nil(retired_at) ->
          {:error, {:chart_retired, %{retired_at: retired_at, retired_by: row.retired_by}}}

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
    Declares the narrow tombstone read (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_retired_info?/1`).

    Always `true`, and unlike `supports_chart_retirement?/1` it does not
    ask the store: the read selects `retired_at` and `retired_by`, which
    `fetch_chart/2` and `save_chart/2` already read on every store this
    adapter serves. A store that can never carry a tombstone answers
    `nil` for every hash, cheaply, which is the answer a create needs.
    """
    @impl Adapter
    @spec supports_retired_info?(Adapter.opts()) :: boolean()
    def supports_retired_info?(_opts), do: true

    @doc """
    Reads the tombstone on `content_hash`, or `nil` for a hash that has
    none (the optional
    `c:StatifierPersistence.Storage.Adapter.fetch_retired_info/2`).

    One `SELECT` of `retired_at` and `retired_by` on the unique index,
    restricted to a tombstoned row, so neither chart blob crosses the
    wire and the cost does not grow with the chart.
    """
    @impl Adapter
    @spec fetch_retired_info(Adapter.opts(), Adapter.content_hash()) ::
            {:ok, Adapter.retired_info() | nil}
    def fetch_retired_info(opts, content_hash) do
      {:ok, retired_info(opts, content_hash)}
    end

    # The tombstone on one hash, or nil for a hash that has none - which
    # includes a hash with no row at all, because "no row" is
    # `:chart_not_found`'s answer to give and not this function's.
    @spec retired_info(Adapter.opts(), Adapter.content_hash()) :: Adapter.retired_info() | nil
    defp retired_info(opts, content_hash) do
      repo(opts).one(
        from(c in chart_schema(opts),
          where: c.content_hash == ^content_hash,
          where: not is_nil(c.retired_at),
          select: %{retired_at: c.retired_at, retired_by: c.retired_by}
        )
      )
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
          # The index name is DDL, not API: V01 creates it and V06 renames
          # it, with the table and the column, on an upgraded install.
          name: "#{Keyword.fetch!(opts, :executions_table)}_execution_id_index"
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
    Declares the drained query (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_content_hash_query?/1`):
    this adapter counts the executions table's rows on one
    `content_hash`, on every Ecto backend.

    Unconditional, unlike `supports_metadata?/1`. The query is an equality
    predicate on a `text` column with a `GROUP BY` over another, which
    every backend this package tests parses, and V07 indexes the column
    it filters on for every backend too.
    """
    @impl Adapter
    @spec supports_content_hash_query?(Adapter.opts()) :: boolean()
    def supports_content_hash_query?(_opts), do: true

    @doc """
    Counts the executions on `content_hash` per stored arm (the optional
    `c:StatifierPersistence.Storage.Adapter.count_executions_by_content_hash/2`,
    ADR-0012 decision 3).

    One grouped count against the V07 index on
    `executions(content_hash)`: no row is loaded and no blob is read,
    which is the point of a callback that answers "what is running on
    this chart" rather than "which executions are".

    The database answers only the arms it holds rows in, so the grouped
    result is folded onto a map of zeros: every key is present for every
    hash, and a hash this store has never seen answers zeros.

    `children` is a second query, because it counts something the
    executions table's own `content_hash` column does not hold: the
    linkage pins naming this hash whose parent execution is `:active` or
    `:needs_migration` (ADR-0012 decision 1, as ADR-0014 decision 4 reads
    it). It is a containment probe on the reserved
    metadata key joined to the parent row by `execution_id`, and
    containment is the operator V03's `jsonb_path_ops` GIN index on
    `metadata` serves.

    Off Postgres it is `0`, and that is the count rather than a gap:
    `supports_metadata?/1` is false there, so
    `StatifierPersistence.Storage.insert_execution/5` refuses a
    `metadata:` option at open and no linkage reaches the table through
    a supported door.
    """
    @impl Adapter
    @spec count_executions_by_content_hash(Adapter.opts(), Adapter.content_hash()) ::
            {:ok, Adapter.execution_counts()} | {:error, Adapter.error()}
    def count_executions_by_content_hash(opts, content_hash) do
      grouped =
        repo(opts).all(
          from(r in execution_schema(opts),
            where: r.content_hash == ^content_hash,
            group_by: r.status,
            select: {r.status, count(r.execution_id)}
          )
        )

      counts =
        Enum.reduce(grouped, @zero_counts, fn {status, count}, counts ->
          Map.put(counts, decode_status(status), count)
        end)

      {:ok, %{counts | children: children_pin_count(opts, content_hash)}}
    end

    # ADR-0012 decision 1's child clause, as decision 3's `children` key:
    # a linkage pin naming this hash counts for as long as the execution
    # its `parent_execution_id` names is `:active` or `:needs_migration`
    # (ADR-0014 decision 4), whatever arm the
    # child itself is in. The child row is matched on its pin rather
    # than on its `content_hash` column, because the pin is the value
    # the decision names and the two are written by separate calls.
    @spec children_pin_count(Adapter.opts(), Adapter.content_hash()) :: non_neg_integer()
    defp children_pin_count(opts, content_hash) do
      if supports_metadata?(opts) do
        repo(opts).one(
          from([child] in exclude(child_pins(opts, content_hash), :select),
            select: count(child.execution_id)
          )
        )
      else
        0
      end
    end

    @doc """
    Lists the ids of the `:active` executions on `content_hash` (the
    optional
    `c:StatifierPersistence.Storage.Adapter.list_active_execution_ids_by_content_hash/2`,
    ADR-0012 decision 4).

    One column, one arm, under the same V07 index on
    `executions(content_hash)` the grouped count uses: the ids are what
    a pin source is handed as its context, and nothing else about those
    executions is read.
    """
    @impl Adapter
    @spec list_active_execution_ids_by_content_hash(Adapter.opts(), Adapter.content_hash()) ::
            {:ok, [Adapter.execution_id()]} | {:error, Adapter.error()}
    def list_active_execution_ids_by_content_hash(opts, content_hash) do
      {:ok,
       repo(opts).all(
         from(r in execution_schema(opts),
           where: r.content_hash == ^content_hash,
           where: r.status == ^encode_status(:active),
           select: r.execution_id
         )
       )}
    end

    @doc """
    Declares whether the store this adapter is pointed at can be
    tombstoned (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_chart_retirement?/1`,
    ADR-0012 decision 6).

    It asks the store, not the backend. The retirement writes `NULL`
    into `identity_blob` and `chart_blob` and writes `retired_at` and
    `retired_by`, so what has to be true is that those four columns are
    there and the two blob columns are nullable - which is exactly what
    migration V07 arranges, and which V07 can only arrange on Postgres,
    because `ecto_sqlite3` raises from the `modify/3` that drops a
    `NOT NULL`.

    Asking the catalog rather than the adapter module keeps the answer
    true for the host V07's moduledoc sends elsewhere: one that altered
    the two columns itself, in a migration of its own on a backend that
    is not Postgres, has a store that can be retired against and this
    predicate says so. One query, on a call a host makes once per
    retirement.

    The probe reads the columns' presence and the two blobs'
    nullability, not their types. A host that adds the tombstone
    columns itself with types other than V07's - `retired_at` as text,
    say - is answered `true` here, and the retirement's `UPDATE` then
    raises the database's own error rather than refusing at open. V07
    writes the types this adapter writes; a hand-built store has to
    match them.
    """
    @impl Adapter
    @spec supports_chart_retirement?(Adapter.opts()) :: boolean()
    def supports_chart_retirement?(opts) do
      schema = chart_schema(opts)

      tombstone_columns_ready?(
        repo(opts),
        schema.__schema__(:prefix),
        schema.__schema__(:source)
      )
    end

    # Four columns have to be in place: the two tombstone columns at
    # all, and the two blob columns nullable. Counting the ones that
    # qualify and comparing against four answers all four questions in
    # one round trip, and answers `false` for a table that is not there
    # rather than raising about the wrong thing - V07's own `down/1`
    # probe takes the same posture.
    @spec tombstone_columns_ready?(Ecto.Repo.t(), String.t() | nil, String.t()) :: boolean()
    defp tombstone_columns_ready?(repo, prefix, charts) do
      sql =
        if repo.__adapter__() == Ecto.Adapters.Postgres do
          "SELECT count(*) FROM information_schema.columns " <>
            "WHERE table_schema = #{schema_expression(prefix)} AND table_name = $1 " <>
            "AND (column_name IN ('retired_at', 'retired_by') " <>
            "OR (column_name IN ('identity_blob', 'chart_blob') AND is_nullable = 'YES'))"
        else
          "SELECT count(*) FROM pragma_table_info(?1) " <>
            "WHERE (name IN ('retired_at', 'retired_by') " <>
            "OR (name IN ('identity_blob', 'chart_blob') AND \"notnull\" = 0))"
        end

      %{rows: [[qualifying]]} = repo.query!(sql, [charts])

      qualifying == 4
    end

    @spec schema_expression(String.t() | nil) :: String.t()
    defp schema_expression(nil), do: "current_schema()"
    defp schema_expression(prefix), do: "'#{String.replace(prefix, "'", "''")}'"

    @doc """
    Retires the chart on `content_hash`: the counts and the tombstone in
    one transaction (the optional
    `c:StatifierPersistence.Storage.Adapter.retire_chart/3`, ADR-0012
    decisions 5 and 6).

    The transaction is what the callback's contract asks for, and one
    thing inside it is worth naming, because it is what closes the race
    the record cares about. The tombstone is not an update the counts
    authorise; it is a single conditional `UPDATE` that re-asserts every
    one of them in its own `WHERE` - no `:active` or `:needs_migration`
    execution row on the
    hash, no position row on it, no durable-child pin naming it, and the
    row not already retired. The counts taken above it are what a
    refusal reports; the `UPDATE` is what decides. So there is no
    interval between the count and the write for an execution to be
    created in: an execution visible when the statement runs is in its
    `NOT EXISTS`, and one committed after it is after the tombstone. A
    statement that matches no row is read back as the refusal it is -
    the counts are taken again and reported, or the retired arm is
    answered if a concurrent retirement won.

    This transaction joins a caller's own when there is one, and it
    takes no per-execution lock: the two contracts the README's
    "Writing inside a caller's transaction" and "Delivering while a
    step is in flight" sections state are untouched by it.

    No row: `:chart_not_found`. Already retired: the retired arm,
    never a second tombstone.
    """
    @impl Adapter
    @spec retire_chart(Adapter.opts(), Adapter.content_hash(), Adapter.retirement()) ::
            {:ok, Adapter.retired_info()} | {:error, Adapter.error()}
    def retire_chart(opts, content_hash, retirement) do
      # No `rollback/1` anywhere below: every refusal writes nothing, so
      # there is nothing to undo, and rolling back here would abort a
      # caller's own transaction over an answer that changed no row.
      {:ok, answer} =
        repo(opts).transaction(fn -> tombstone(opts, content_hash, retirement) end)

      answer
    end

    @spec tombstone(Adapter.opts(), Adapter.content_hash(), Adapter.retirement()) ::
            {:ok, Adapter.retired_info()} | {:error, Adapter.error()}
    defp tombstone(opts, content_hash, retirement) do
      # Only the miss is decided here. An already-retired row is left to
      # the conditional UPDATE's own `retired_at IS NULL` clause and to
      # `written/4`, which reads the tombstone back: one guard, in the
      # statement that writes, rather than a pre-check the statement
      # then repeats.
      if is_nil(repo(opts).get_by(chart_schema(opts), content_hash: content_hash)) do
        {:error, :chart_not_found}
      else
        counted(opts, content_hash, retirement)
      end
    end

    @spec counted(Adapter.opts(), Adapter.content_hash(), Adapter.retirement()) ::
            {:ok, Adapter.retired_info()} | {:error, Adapter.error()}
    defp counted(opts, content_hash, retirement) do
      # This package's own three pin kinds are guarded inside the
      # conditional UPDATE and are deliberately not re-checked here: one
      # guard, in the statement that writes, is what makes "between the
      # count and the write" an interval with nothing in it. A source's
      # counts cannot be guarded there - they were taken outside the
      # database and arrive as data - so they are the one kind checked
      # before the statement runs.
      if Adapter.sources_pinned?(retirement.sources) do
        {:error, {:pinned, pin_counts(opts, content_hash, retirement.sources)}}
      else
        written(opts, content_hash, retirement, write_tombstone(opts, content_hash, retirement))
      end
    end

    # A conditional UPDATE that matched nothing means something arrived
    # between the counts above and the statement itself: either a pin,
    # or another retirement. Which one it was is read back rather than
    # guessed. The read-back is a fresh count, and under READ COMMITTED
    # it sees what has committed since the UPDATE ran, so a pin that won
    # the race and has already gone again - an execution that reached a
    # terminal arm, a position row deleted - is not in it: the refusal
    # then carries a map of zeros. It is still a refusal and still wrote
    # nothing, and the next retirement of the same hash is decided
    # afresh; what the zeros cannot do is name the pin that refused.
    @spec written(
            Adapter.opts(),
            Adapter.content_hash(),
            Adapter.retirement(),
            non_neg_integer()
          ) :: {:ok, Adapter.retired_info()} | {:error, Adapter.error()}
    defp written(_opts, _content_hash, retirement, 1) do
      {:ok, %{retired_at: retirement.retired_at, retired_by: retirement.retired_by}}
    end

    defp written(opts, content_hash, retirement, 0) do
      case retired_info(opts, content_hash) do
        nil -> {:error, {:pinned, pin_counts(opts, content_hash, retirement.sources)}}
        info -> {:error, {:chart_retired, info}}
      end
    end

    @spec pin_counts(Adapter.opts(), Adapter.content_hash(), Adapter.source_counts()) ::
            Adapter.pin_counts()
    defp pin_counts(opts, content_hash, sources) do
      {:ok, counts} = count_executions_by_content_hash(opts, content_hash)

      Adapter.pin_counts(counts, position_count(opts, content_hash), sources)
    end

    # ADR-0012 decision 1's fourth pin kind, and the one the drained
    # query's map deliberately leaves out: a position row is a saved
    # session waiting to be resumed through `load_position/3`, which
    # needs the bytes this retirement would null. Positions are keyed by
    # session, so a hash with no execution row at all can still hold
    # them.
    @spec position_count(Adapter.opts(), Adapter.content_hash()) :: non_neg_integer()
    defp position_count(opts, content_hash) do
      repo(opts).one(
        from(p in position_schema(opts),
          where: p.content_hash == ^content_hash,
          select: count(p.session_id)
        )
      )
    end

    @spec write_tombstone(Adapter.opts(), Adapter.content_hash(), Adapter.retirement()) ::
            non_neg_integer()
    defp write_tombstone(opts, content_hash, retirement) do
      {written, _rows} =
        repo(opts).update_all(unpinned_chart(opts, content_hash),
          set: [
            retired_at: retirement.retired_at,
            retired_by: retirement.retired_by,
            identity_blob: nil,
            chart_blob: nil,
            updated_at: retirement.retired_at
          ]
        )

      written
    end

    # The blocking set of ADR-0012 decision 1, as the WHERE of the one
    # statement that writes the tombstone. A parked execution pins its
    # chart like an active one (ADR-0014 decision 4). The three terminal
    # execution arms are absent on purpose: they are reported in a
    # refusal and never cause one.
    @spec unpinned_chart(Adapter.opts(), Adapter.content_hash()) :: Ecto.Query.t()
    defp unpinned_chart(opts, content_hash) do
      executions = execution_schema(opts)
      positions = position_schema(opts)

      active =
        from(r in executions,
          where: r.content_hash == ^content_hash,
          where: r.status in ^pinning_statuses(),
          select: 1
        )

      held =
        from(p in positions,
          where: p.content_hash == ^content_hash,
          select: 1
        )

      unpinned =
        from(c in chart_schema(opts),
          where: c.content_hash == ^content_hash,
          where: is_nil(c.retired_at),
          where: not exists(subquery(active)),
          where: not exists(subquery(held))
        )

      without_child_pins(unpinned, opts, content_hash)
    end

    # An adapter holding no metadata holds no linkage pin, so there is
    # no clause to add - the same reading `children_pin_count/2` takes
    # of the same fact.
    @spec without_child_pins(Ecto.Query.t(), Adapter.opts(), Adapter.content_hash()) ::
            Ecto.Query.t()
    defp without_child_pins(query, opts, content_hash) do
      if supports_metadata?(opts) do
        pins = child_pins(opts, content_hash)

        from(_c in query, where: not exists(subquery(pins)))
      else
        query
      end
    end

    # The one reading of decision 1's child clause, as a query over the
    # child rows: `children_pin_count/2` counts it and
    # `without_child_pins/3` asks that it is empty, so the pin a refusal
    # reports and the pin the tombstone's statement guards are one pin
    # by construction.
    @spec child_pins(Adapter.opts(), Adapter.content_hash()) :: Ecto.Query.t()
    defp child_pins(opts, content_hash) do
      reserved = Linkage.reserved_key()
      pin_match = %{reserved => %{"content_hash" => content_hash}}
      executions = execution_schema(opts)

      from(child in executions,
        join: parent in ^executions,
        on:
          parent.execution_id ==
            fragment(
              "?->?->>?",
              child.metadata,
              type(^reserved, :string),
              type(^"parent_execution_id", :string)
            ),
        where: fragment("? @> ?", child.metadata, type(^pin_match, :map)),
        where: parent.status in ^pinning_statuses(),
        select: 1
      )
    end

    # The stored arms whose execution pins a chart (ADR-0012 decision 1,
    # as ADR-0014 decision 4 reads it): an execution row on the hash in
    # one of these arms blocks a retirement, and so does a durable
    # child's pin while its parent is in one of them.
    @spec pinning_statuses() :: [String.t()]
    defp pinning_statuses, do: [encode_status(:active), encode_status(:needs_migration)]

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
    Declares the tree migration unit (the optional
    `c:StatifierPersistence.Storage.Adapter.supports_tree_migration?/1`,
    ADR-0015 decision 3): its writes are `UPDATE`s of existing columns, and
    the linkage pin lives in the existing metadata column, so it needs no
    schema version.
    """
    @impl Adapter
    @spec supports_tree_migration?(Adapter.opts()) :: boolean()
    def supports_tree_migration?(_opts), do: true

    @doc """
    Writes a tree migration's re-pins and parks in one transaction (the
    optional `c:StatifierPersistence.Storage.Adapter.write_tree_migration/2`,
    ADR-0015 decision 3).

    Every execution the writes name is read first, and one that is not
    stored is `{:error, :execution_not_found}` before any write is made:
    that refusal writes nothing, so it is returned as it is and nothing is
    rolled back, as `retire_chart/3` returns its refusals. Reached inside a
    caller's own transaction - the per-execution lock's is one - the
    transaction joins it, so the refusal reaches the caller as the
    adapter's own reason and the enclosing transaction is left open.

    Each write is then one `update_all/3` keyed on `execution_id`. A write
    that still matches no row rolls the transaction back with
    `rollback/1`, so the writes before it are undone; inside a caller's
    own transaction that aborts the enclosing one too, which then answers
    its own rollback: a failure after a write must not return an error the
    enclosing transaction would then commit (the callback's contract).
    """
    @impl Adapter
    @spec write_tree_migration(Adapter.opts(), [Adapter.tree_write()]) ::
            :ok | {:error, Adapter.error()}
    def write_tree_migration(opts, writes) when is_list(writes) do
      repo = repo(opts)

      transaction =
        repo.transaction(fn ->
          with :ok <- tree_rows_stored(opts, writes), do: tree_writes(repo, opts, writes)
        end)

      case transaction do
        {:ok, answer} -> answer
        {:error, _reason} = error -> error
      end
    end

    # A refusal decided before the first write writes nothing, so it needs
    # no `rollback/1`: returning it keeps the adapter's own reason, where a
    # rollback inside the lock's transaction would reach the caller as the
    # lock's `{:adapter, :rollback}` (ADR-0015's sp-4bnu Amendment).
    @spec tree_rows_stored(Adapter.opts(), [Adapter.tree_write()]) ::
            :ok | {:error, Adapter.error()}
    defp tree_rows_stored(opts, writes) do
      named = writes |> Enum.map(&tree_write_id/1) |> Enum.uniq()

      stored =
        repo(opts).all(
          from(r in execution_schema(opts),
            where: r.execution_id in ^named,
            select: r.execution_id
          )
        )

      if length(stored) == length(named), do: :ok, else: {:error, :execution_not_found}
    end

    defp tree_write_id({:repin, %{execution_id: execution_id}, _linkage_hash}), do: execution_id
    defp tree_write_id({:park, execution_id}), do: execution_id

    # A write that matches no row after `tree_rows_stored/2` has read every
    # one rolls the unit back, undoing the writes before it.
    @spec tree_writes(module(), Adapter.opts(), [Adapter.tree_write()]) :: :ok
    defp tree_writes(repo, opts, writes) do
      case Enum.reduce_while(writes, :ok, &tree_step(opts, &1, &2)) do
        :ok -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end

    @spec tree_step(Adapter.opts(), Adapter.tree_write(), :ok) ::
            {:cont, :ok} | {:halt, {:error, Adapter.error()}}
    defp tree_step(opts, write, :ok) do
      case tree_write(opts, write) do
        {1, _returned} -> {:cont, :ok}
        {0, _returned} -> {:halt, {:error, :execution_not_found}}
      end
    end

    # A re-pin is `update_execution/2`'s statement with the one sanctioned
    # rewrite of the linkage pin (ADR-0008's 2026-09-23 Amendment); a park is
    # a status write, as `Storage.update_execution_status/4` makes one.
    defp tree_write(opts, {:repin, %{execution_id: execution_id} = record, linkage_hash}) do
      query = from(r in execution_schema(opts), where: r.execution_id == ^execution_id)

      updates =
        [
          status: encode_status(record.status),
          content_hash: record.content_hash,
          identity_blob: record.identity_blob,
          position_blob: record.position_blob,
          failure: record.failure,
          updated_at: DateTime.utc_now()
        ] ++
          outcome_update(Map.get(record, :outcome_blob)) ++
          linkage_update(opts, execution_id, linkage_hash)

      repo(opts).update_all(query, set: updates)
    end

    defp tree_write(opts, {:park, execution_id}) do
      query = from(r in execution_schema(opts), where: r.execution_id == ^execution_id)

      repo(opts).update_all(query,
        set: [
          status: encode_status(:needs_migration),
          failure: nil,
          updated_at: DateTime.utc_now()
        ]
      )
    end

    # Only the pin's `content_hash` changes; every other key under the
    # reserved namespace, and every host key, is written back as it was read.
    @spec linkage_update(Adapter.opts(), Adapter.execution_id(), Adapter.content_hash() | nil) ::
            keyword()
    defp linkage_update(_opts, _execution_id, nil), do: []

    defp linkage_update(opts, execution_id, linkage_hash) do
      stored =
        repo(opts).one(
          from(r in execution_schema(opts),
            where: r.execution_id == ^execution_id,
            select: r.metadata
          )
        )

      case stored do
        %{} = metadata ->
          case Map.fetch(metadata, Linkage.reserved_key()) do
            {:ok, %{} = reserved} ->
              [
                metadata:
                  Map.put(
                    metadata,
                    Linkage.reserved_key(),
                    Map.put(reserved, "content_hash", linkage_hash)
                  )
              ]

            _no_linkage ->
              []
          end

        nil ->
          []
      end
    end

    @doc """
    Runs `fun` under per-execution mutual exclusion for `execution_id` (the optional
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
          # DDL again: V05 creates this name and V06 renames it.
          name: "#{Keyword.fetch!(opts, :inputs_table)}_execution_id_seq_index"
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
