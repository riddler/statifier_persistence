defmodule StatifierPersistence.Retention do
  @moduledoc """
  Clearing what a finished execution leaves behind (ADR-0016).

  An execution that has ended still stores its last position blob and,
  on an adapter that keeps one, its whole input log (ADR-0010) - the
  host's own event data, at rest, for the life of the store. `prune/3`
  clears both for every execution that ended before a cutoff the host
  names, and keeps the execution row itself: its status, its failure,
  its metadata, its answer and its end stamp stay, so the drained query
  still counts it, a parent can still read a child's answer, and the
  execution id stays taken.

  There is no clock here. The cutoff is a `t:DateTime.t/0` the host
  computes from its own policy; nothing in this module takes a duration,
  defaults a window, or runs on a schedule (ADR-0012 decision 7). Which
  rows a host may delete on its own, and which it must not, is
  `docs/retention.md`.
  """

  alias StatifierPersistence.Storage
  alias StatifierPersistence.Storage.Adapter

  @default_batch_size 500

  @typedoc "Options `prune/3` accepts."
  @type prune_opt ::
          {:batch_size, pos_integer()}
          | {:scope, Adapter.prune_scope()}
          | {:single_batch, boolean()}

  @typedoc """
  What `prune/3` answers for `single_batch: true`: one batch's own counts
  plus whether another call may find more.
  """
  @type batch_counts :: %{
          executions: non_neg_integer(),
          position_blobs: non_neg_integer(),
          inputs: non_neg_integer(),
          more?: boolean()
        }

  @doc """
  Clears the position blob and the input log of every execution that
  ended before `cutoff`, in batches, and answers what it cleared.

  An execution is pruned when its status is `:completed`, `:failed` or
  `:cancelled` and its `ended_at` is set and strictly before `cutoff`.
  An execution with no end stamp is never touched, and neither is one
  whose row carries a stamp but was written back to a status that is not
  terminal. The execution row stays; see the moduledoc for what it keeps.

  Answers `{:ok, counts}` summed over every batch: `executions` pruned,
  `position_blobs` nulled among them, and input log rows deleted. It is
  idempotent: a second call with the same cutoff answers zeros, because
  an execution with nothing left to clear is not selected again.

  Each batch is one atomic unit in the adapter and commits on its own,
  unless a caller's transaction encloses the call (see below).
  So an `{:error, reason}` from a later batch leaves the earlier batches
  pruned, and calling again with the same cutoff carries on from where
  the failed batch stopped.

  `{:error, :execution_pruning_unsupported}` for a store whose adapter
  does not declare the capability
  (`StatifierPersistence.Storage.execution_pruning_supported?/1`),
  before anything is read.

  `{:error, :unscoped_adapter}` when `:scope` is given and the store's
  adapter cannot confine a batch to it - the in-memory adapter is one -
  before anything is cleared.

  Raises `ArgumentError` when `cutoff` is not a `t:DateTime.t/0` - a
  duration, a number of days or a `Date` included - when `:batch_size`
  is not a positive integer, and when `:scope` is not a non-empty keyword
  list of distinct columns with no `nil` value.

  ## Options

  - `:batch_size` - at most how many executions one batch prunes.
    Defaults to #{@default_batch_size}. Smaller batches hold shorter
    transactions; the answer is the same.
  - `:scope` - a keyword list of column equalities, such as
    `[tenant_id: "tenant-a"]`, that confines the prune to the rows
    holding every one of them. Every batch's selection, input log check,
    input log delete and position blob update carries the equalities, so
    a prune run inside one partition's transaction reads and writes no
    row of another. On `StatifierPersistence.Storage.Ecto` the columns
    are ones the host placed with `:leading_columns`. Left out, the prune
    covers the whole store, as it always has. `nil` is refused rather
    than read as `IS NULL`, because an equality with `NULL` matches no
    row.
  - `:single_batch` - `false` (the default) drains every batch as before.
    `true` runs exactly one batch and answers that batch's own counts
    plus `more?`: `true` when the batch took as many executions as
    `batch_size:` allows, so another call may find more; `false` when it
    took fewer, the same point where the default drain stops. When the
    last due batch holds exactly `batch_size:` executions, that call
    answers `more?: true` and the next one answers zeros with `more?:
    false`. A row another transaction holds locked (on Postgres) is
    skipped, not waited on, so it is left for a later call either way.

  ## Inside a transaction of your own

  Each batch is its own transaction only when nothing encloses it. On
  `StatifierPersistence.Storage.Ecto` a batch's transaction joins a
  caller's enclosing transaction, so `prune/3` called inside one runs the
  whole drain - every batch - as one transaction that commits or rolls
  back with the caller's. `:batch_size` then bounds each batch's
  statements, not the transaction.

  For one bounded transaction per batch - for example one that first sets
  a partition's context - call `prune/3` with `single_batch: true` inside
  each of your transactions, and call again while `more?` is `true`:

      def prune_tenant(store, cutoff, tenant_id) do
        batch =
          Repo.transaction(fn ->
            # set the tenant's context for this transaction here, then:
            opts = [scope: [tenant_id: tenant_id], single_batch: true]

            case Retention.prune(store, cutoff, opts) do
              {:ok, counts} -> counts
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        with {:ok, %{more?: true}} <- batch do
          prune_tenant(store, cutoff, tenant_id)
        end
      end

  It answers `{:ok, counts}` for the last batch, `more?: false`, or the
  first `{:error, reason}`, with every earlier batch committed.
  """
  @spec prune(store :: Storage.t(), cutoff :: DateTime.t(), opts :: [prune_opt()]) ::
          {:ok, Adapter.prune_counts() | batch_counts()} | {:error, Storage.error()}
  def prune(store, cutoff, opts \\ [])

  def prune(%Storage{} = store, %DateTime{} = cutoff, opts) when is_list(opts) do
    batch_size = batch_size!(opts)
    scope = scope!(opts)
    single_batch = single_batch!(opts)

    if Storage.execution_pruning_supported?(store) do
      if single_batch do
        prune_one_batch(store, cutoff, batch_size, scope)
      else
        prune_batches(store, cutoff, batch_size, scope, %{
          executions: 0,
          position_blobs: 0,
          inputs: 0
        })
      end
    else
      {:error, :execution_pruning_unsupported}
    end
  end

  def prune(%Storage{}, cutoff, _opts) do
    raise ArgumentError,
          "prune/3 takes the cutoff as a DateTime the host computed from its own " <>
            "policy - this package takes no duration and defaults no window " <>
            "(ADR-0012 decision 7), got: #{inspect(cutoff)}"
  end

  # A batch that answers fewer executions than it may take found
  # everything that was due, so the loop stops there rather than asking
  # once more for an answer of zero.
  @spec prune_batches(
          Storage.t(),
          DateTime.t(),
          pos_integer(),
          Adapter.prune_scope(),
          Adapter.prune_counts()
        ) :: {:ok, Adapter.prune_counts()} | {:error, Storage.error()}
  defp prune_batches(store, cutoff, batch_size, scope, total) do
    case Storage.prune_executions(store, cutoff, batch_size, scope) do
      {:ok, counts} ->
        total = %{
          executions: total.executions + counts.executions,
          position_blobs: total.position_blobs + counts.position_blobs,
          inputs: total.inputs + counts.inputs
        }

        if counts.executions < batch_size,
          do: {:ok, total},
          else: prune_batches(store, cutoff, batch_size, scope, total)

      {:error, _reason} = error ->
        error
    end
  end

  # A single batch, answered with `more?` rather than summed into a
  # running total: `more?` is the loop's own stop, handed to the host.
  @spec prune_one_batch(
          Storage.t(),
          DateTime.t(),
          pos_integer(),
          Adapter.prune_scope()
        ) :: {:ok, batch_counts()} | {:error, Storage.error()}
  defp prune_one_batch(store, cutoff, batch_size, scope) do
    case Storage.prune_executions(store, cutoff, batch_size, scope) do
      {:ok, counts} ->
        {:ok, Map.put(counts, :more?, counts.executions == batch_size)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec batch_size!([prune_opt()]) :: pos_integer()
  defp batch_size!(opts) do
    case Keyword.get(opts, :batch_size, @default_batch_size) do
      size when is_integer(size) and size > 0 ->
        size

      other ->
        raise ArgumentError,
              "prune/3 requires `batch_size:` to be a positive integer, got: #{inspect(other)}"
    end
  end

  # No `:scope` is no scope, which the adapter reads as `[]`. A given
  # scope must name at least one column: a scope computed to nothing
  # would otherwise prune every partition from inside one.
  @spec scope!([prune_opt()]) :: Adapter.prune_scope()
  defp scope!(opts) do
    case Keyword.fetch(opts, :scope) do
      :error -> []
      {:ok, scope} -> validate_scope!(scope)
    end
  end

  @spec validate_scope!(term()) :: Adapter.prune_scope()
  defp validate_scope!([_ | _] = scope) do
    columns = if Keyword.keyword?(scope), do: Keyword.keys(scope), else: nil

    cond do
      is_nil(columns) ->
        raise_scope!(scope, "a keyword list of column: value")

      length(Enum.uniq(columns)) != length(columns) ->
        raise_scope!(scope, "each column named once")

      Enum.any?(scope, fn {_column, value} -> is_nil(value) end) ->
        raise_scope!(scope, "no nil value - an equality with NULL matches no row")

      true ->
        scope
    end
  end

  defp validate_scope!(scope) do
    raise_scope!(
      scope,
      "a non-empty keyword list of column: value - leave it out to prune the whole store"
    )
  end

  @spec raise_scope!(term(), String.t()) :: no_return()
  defp raise_scope!(scope, requirement) do
    raise ArgumentError,
          "prune/3 requires `scope:` to be #{requirement}, got: #{inspect(scope)}"
  end

  @spec single_batch!([prune_opt()]) :: boolean()
  defp single_batch!(opts) do
    case Keyword.get(opts, :single_batch, false) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError,
              "prune/3 requires `single_batch:` to be true or false, got: #{inspect(other)}"
    end
  end
end
