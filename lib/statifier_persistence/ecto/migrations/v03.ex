if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V03 do
    @moduledoc """
    V03 of the package DDL: the runs table's nullable `outcome_blob`
    column, and a GIN index on `metadata`.

    ## `outcome_blob`

    A run's own answer, kept where a reader that has never seen the run
    live can find it. A durable subchart child's completion used to exist
    only on the step that produced it - a stored record carries no
    donedata - which is fine while a completion is answered immediately
    and not fine once N of them have to be collected and assembled in
    index order. The column is written once, at the child's completion,
    by `StatifierPersistence.Storage.update_run_status/4`.

    Nullable, because almost no run has one: an ordinary run answers
    nobody, and a run that fails at creation never completes.

    It is a **blob** column, not a `jsonb` one, and the difference is a
    disclosure decision rather than a typing convenience. `metadata` is
    restricted to host identities (ADR-0006 decision 2) precisely because
    `:blob_type` encryption does not reach a queryable column. A donedata
    payload carries whatever the chart's author put in it, so it belongs
    on the side of that line the encryption reaches: `outcome_blob` joins
    the three existing blob columns and takes the configured `:blob_type`
    with them.

    ## The `metadata` GIN index

    V02 shipped no index and said why: which pairs a host queries by is
    the host's call (ADR-0006 decision 4). Fan-out settlement changes the
    arithmetic. Every child completion asks "are all N of my siblings
    terminal?", which is the same `jsonb` containment query the cascade
    already issues, so one fan-out of N children issues N of them; without
    an index each is a sequential scan of the host's whole runs table.
    That is not a cost a host can be left to discover in production, so
    this package now ships the index the query it issues needs.

    `jsonb_path_ops` rather than the default `jsonb_ops`: containment
    (`@>`) is the only operator either query uses, and the path-ops
    opclass serves exactly that, with a smaller index. A host that needs
    the wider operator set, or an expression index on particular keys,
    still adds its own - ADR-0006 decision 4's clause is narrowed by this
    migration, not withdrawn, and the record carries a dated Note saying
    so.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc """
    Adds the runs table's nullable `outcome_blob` column and the
    `metadata` GIN index per `config`.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      runs = Config.table(config, :runs)

      alter table(runs, prefix: config.prefix) do
        add(:outcome_blob, :binary, null: true)
      end

      create(
        index(runs, ["metadata jsonb_path_ops"],
          using: "GIN",
          name: index_name(runs),
          prefix: config.prefix
        )
      )

      :ok
    end

    @doc "Drops the `metadata` GIN index and the runs table's `outcome_blob` column."
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      runs = Config.table(config, :runs)

      drop(index(runs, ["metadata"], name: index_name(runs), prefix: config.prefix))

      alter table(runs, prefix: config.prefix) do
        remove(:outcome_blob)
      end

      :ok
    end

    # Named explicitly rather than left to Ecto's derivation, which builds
    # a name out of the expression text: `down/1` has to name the same
    # index `up/1` created, and an expression-derived name is not
    # something a reader of this module can check by eye.
    @spec index_name(String.t()) :: atom()
    defp index_name(runs), do: :"#{runs}_metadata_gin_index"
  end
end
