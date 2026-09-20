if Code.ensure_loaded?(Ecto.Migration) do
  defmodule StatifierPersistence.Ecto.Migrations.V07 do
    @moduledoc """
    V07 of the package DDL: what retention and retirement need in the
    schema (ADR-0012).

    Five changes, one version:

    - a non-unique index on `executions(content_hash)`, which the drained
      query groups under and which no earlier version provides - V01
      indexes `execution_id` and V03 and V04 index `metadata`, so a count
      of the executions on one hash was a sequential scan of the host's
      whole executions table;
    - `retired_at`, a nullable `utc_datetime_usec` on `charts`;
    - `retired_by`, a nullable `text` column on `charts`;
    - `identity_blob` and `chart_blob` on `charts` made nullable.

    The last two are what makes a retirement executable at all. V01
    declares both blob columns `null: false` and no version between V01
    and this one alters `charts`, so nulling a retired chart's bytes -
    which is what the removal *is* (ADR-0012 decision 6) - could not run
    against the schema as it stood.

    ## Adapters other than Postgres

    `ALTER COLUMN` is not a statement SQLite has, and `ecto_sqlite3`
    raises `ArgumentError` from `modify/3` rather than emitting one.
    Dropping a `NOT NULL` there means rebuilding the table and copying
    every row into the copy, which is not something this package's DDL
    does to a host's data - V06 records the same posture for the rename.

    So the two `modify` changes are guarded, the way V03 guards its
    Postgres-only index, and the index and the two new columns are
    created on every backend. The consequence is worth stating plainly:
    **on a backend that is not Postgres the blob columns keep
    `null: false`, so a retirement cannot null them and fails on the
    constraint.** The chart doors, the drained query and the pin counting
    are unaffected; retiring a chart is a Postgres capability under this
    version, and a host on another backend that needs it alters the two
    columns in a migration of its own.

    ## Rolling back over a retired chart is refused

    `down/1` reverses all five changes, and the reversal of the last two
    is the one that cannot always be done. A retired chart's row is still
    there - that is what a tombstone is - and its `identity_blob` and
    `chart_blob` are `NULL`, because the retirement removed the bytes.
    There are no bytes to put back, so restoring `null: false` over such
    a row is impossible, and the two answers that do not involve
    inventing data are to fail the rollback or to leave the constraint
    off and report nothing.

    This version fails it, loudly, before it has changed anything: `down/1`
    asks first whether any `charts` row carries a `retired_at`, and
    raises naming the table and the count when one does. A host that
    means to roll back past this version deletes the tombstoned rows
    itself first - the charts they stood for are gone either way, and
    `StatifierPersistence.Storage.save_chart/3` refuses to revive one
    (ADR-0012 decision 6) - and runs the rollback again.

    The check is the same on every backend. What it asks about is the
    tombstone, not the column definition, so the rule does not vary with
    what `up/1` was able to do on that backend.

    ## The probe runs late

    The existence and tombstone queries go through
    `Ecto.Migration.execute/1`'s function form rather than running in the
    body of `down/1`, for the reason V04 and V06 record: Ecto's migration
    runner queues a migration's commands and runs them at the end, so a
    query issued from the body reaches the database out of order with the
    DDL around it. A queued function runs in order - here, before the
    removals it guards.
    """

    use Ecto.Migration

    alias StatifierPersistence.Ecto.Config

    @doc """
    Adds the `executions(content_hash)` index, the two tombstone columns
    on `charts`, and - on Postgres - the two nullable blob columns, per
    `config`.
    """
    @spec up(Config.t()) :: :ok
    def up(%Config{} = config) do
      executions = Config.table(config, :executions)
      charts = Config.table(config, :charts)

      create(
        index(executions, [:content_hash],
          name: content_hash_index_name(executions),
          prefix: config.prefix
        )
      )

      alter table(charts, prefix: config.prefix) do
        add(:retired_at, :utc_datetime_usec, null: true)
        add(:retired_by, :text, null: true)
      end

      if postgres?() do
        alter table(charts, prefix: config.prefix) do
          modify(:identity_blob, :binary, null: true)
          modify(:chart_blob, :binary, null: true)
        end
      end

      :ok
    end

    @doc """
    Reverses all five changes, refusing first when any `charts` row is
    tombstoned - see the moduledoc.
    """
    @spec down(Config.t()) :: :ok
    def down(%Config{} = config) do
      executions = Config.table(config, :executions)
      charts = Config.table(config, :charts)

      execute(fn -> refuse_over_a_tombstone!(config, charts) end)

      if postgres?() do
        alter table(charts, prefix: config.prefix) do
          modify(:identity_blob, :binary, null: false)
          modify(:chart_blob, :binary, null: false)
        end
      end

      alter table(charts, prefix: config.prefix) do
        remove(:retired_by)
        remove(:retired_at)
      end

      drop(
        index(executions, [:content_hash],
          name: content_hash_index_name(executions),
          prefix: config.prefix
        )
      )

      :ok
    end

    # A rollback over a database this version never reached has nothing to
    # refuse over, and asking a table that is not there is an error about
    # the wrong thing.
    @spec refuse_over_a_tombstone!(Config.t(), String.t()) :: :ok
    defp refuse_over_a_tombstone!(%Config{} = config, charts) do
      repo = repo()

      if tombstone_column_exists?(repo, config, charts) do
        refuse_on_count!(repo, config, charts, tombstoned_count(repo, config, charts))
      end

      :ok
    end

    @spec refuse_on_count!(Ecto.Repo.t(), Config.t(), String.t(), non_neg_integer()) :: :ok
    defp refuse_on_count!(_repo, _config, _charts, 0), do: :ok

    defp refuse_on_count!(_repo, _config, charts, count) do
      raise "cannot roll back statifier_persistence V07 over a retired chart: " <>
              "#{count} row(s) in #{charts} carry a retired_at. A retirement nulled " <>
              "their identity_blob and chart_blob (ADR-0012 decision 6), so there are " <>
              "no bytes to restore and this rollback cannot put NOT NULL back on those " <>
              "columns. Delete the retired rows and run the rollback again."
    end

    @spec tombstoned_count(Ecto.Repo.t(), Config.t(), String.t()) :: non_neg_integer()
    defp tombstoned_count(repo, config, charts) do
      %{rows: [[count]]} =
        repo.query!(
          "SELECT count(*) FROM #{qualified(config, charts)} WHERE \"retired_at\" IS NOT NULL",
          []
        )

      count
    end

    @spec tombstone_column_exists?(Ecto.Repo.t(), Config.t(), String.t()) :: boolean()
    defp tombstone_column_exists?(repo, config, charts) do
      if postgres?() do
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
            "WHERE table_schema = #{schema_expression(config)} " <>
            "AND table_name = #{literal(charts)} AND column_name = 'retired_at')"
        )
      else
        truthy?(
          repo,
          "SELECT EXISTS (SELECT 1 FROM pragma_table_info(#{literal(charts)}) " <>
            "WHERE name = 'retired_at')"
        )
      end
    end

    @spec schema_expression(Config.t()) :: String.t()
    defp schema_expression(%Config{prefix: nil}), do: "current_schema()"
    defp schema_expression(%Config{prefix: prefix}), do: literal(prefix)

    @spec truthy?(Ecto.Repo.t(), String.t()) :: boolean()
    defp truthy?(repo, sql) do
      %{rows: [[answer]]} = repo.query!(sql, [])

      answer in [true, 1]
    end

    @spec qualified(Config.t(), String.t()) :: String.t()
    defp qualified(%Config{prefix: nil}, name), do: quoted(name)
    defp qualified(%Config{prefix: prefix}, name), do: "#{quoted(prefix)}.#{quoted(name)}"

    @spec quoted(String.t()) :: String.t()
    defp quoted(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

    @spec literal(String.t()) :: String.t()
    defp literal(value), do: "'#{String.replace(value, "'", "''")}'"

    # Named explicitly rather than left to Ecto's derivation, for V03's
    # reason: `down/1` has to drop the index `up/1` created, under a name
    # a reader of this module can check by eye.
    @spec content_hash_index_name(String.t()) :: atom()
    defp content_hash_index_name(executions), do: :"#{executions}_content_hash_index"

    # `Ecto.Migration.repo/0` answers the repo the runner is migrating, and
    # an exact match on the adapter rather than a "does it look like
    # Postgres" test, for the reason V03 records.
    @spec postgres?() :: boolean()
    defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
  end
end
