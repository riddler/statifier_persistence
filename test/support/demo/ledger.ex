defmodule StatifierPersistence.Demo.Ledger do
  @moduledoc """
  The demo host's own durable store: an `Agent` standing in for the
  embedder's own database tables (`docs/plans/260822-sp-4an.4-restart-demo-host.md`,
  Phase 1). Unlike `StatifierPersistence.Storage`, this survives a
  simulated restart *by construction* - it is never stopped alongside
  `StatifierPersistence.Demo.Runtime`, only the volatile layer is.

  Started per test with `start_supervised!/1` and carried on the
  `StatifierPersistence.Demo.Host` struct by pid, so demo tests stay
  `async: true` - there is no global name to collide on.

  Four tables:

  - `timers` - pending durable sends, keyed by `{execution_id, ordinal}`
    (st-ADR-0059's dedup key: the counter triple and the content position
    alone cannot tell two `<foreach>` iterations of the same `<send>` apart,
    only `ordinal` can).
  - `invocations` - open/closed async invocations, keyed by
    `{execution_id, invoke_id}`.
  - `side_effects` - the append-only idempotency ledger: `arm_timer/3` and
    `record_invocation/3` each append here only the first time their key is
    seen, which is what lets a test assert "no duplicate side effects"
    independently of the executor call log.
  - `executor_calls` - every `{effect, context}` pair the demo host's
    executor saw, in call order - the log the bead's success criteria ask
    to assert exactly.
  """

  use Agent

  @type execution_id :: String.t()
  @type ordinal :: pos_integer()
  @type timer_key :: {execution_id(), ordinal()}
  @type invocation_key :: {execution_id(), String.t()}
  @type timer_row :: %{
          send_id: String.t() | nil,
          event: String.t(),
          data: term(),
          due_at_ms: non_neg_integer(),
          ordinal: ordinal()
        }
  @type invocation_row :: %{
          invoke_id: String.t(),
          type: String.t() | nil,
          params: term(),
          status: :open | :done
        }
  @type side_effect_key :: {atom(), term()}

  @type t :: pid()

  @type state :: %{
          timers: %{timer_key() => timer_row()},
          invocations: %{invocation_key() => invocation_row()},
          side_effects: [side_effect_key()],
          executor_calls: [{Statifier.Effect.t(), StatifierPersistence.Executor.context()}]
        }

  @doc "Starts a fresh, empty ledger. `opts` is unused; `start_supervised!/1`'s own signature."
  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn ->
      %{timers: %{}, invocations: %{}, side_effects: [], executor_calls: []}
    end)
  end

  @doc """
  Records a pending durable timer, idempotent on `{execution_id, timer.ordinal}`.
  A second call under the same key (a re-driven step, or `recover/1`
  re-arming) leaves the stored row and the `side_effects` log untouched.
  """
  @spec arm_timer(t(), execution_id(), timer_row()) :: :ok
  def arm_timer(ledger, execution_id, %{ordinal: ordinal} = row) do
    key = {execution_id, ordinal}

    Agent.update(ledger, fn state ->
      if Map.has_key?(state.timers, key) do
        state
      else
        state
        |> put_in([:timers, key], row)
        |> append_side_effect({:arm_timer, key})
      end
    end)
  end

  @doc """
  Drops every timer row under `execution_id` whose `send_id` matches, returning
  the removed rows' ordinals. `<cancel sendid>` names a send id, not an
  ordinal, and more than one armed row can share a send id (two iterations
  of the same authored `<send>`), so this can remove more than one row.
  """
  @spec cancel_timer(t(), execution_id(), String.t() | nil) :: [ordinal()]
  def cancel_timer(ledger, execution_id, send_id) do
    Agent.get_and_update(ledger, fn state ->
      {removed, kept} =
        Enum.split_with(state.timers, fn {{r, _ordinal}, row} ->
          r == execution_id and row.send_id == send_id
        end)

      ordinals = removed |> Enum.map(fn {{_r, ordinal}, _row} -> ordinal end) |> Enum.sort()
      {ordinals, %{state | timers: Map.new(kept)}}
    end)
  end

  @doc "Unconditionally drops the timer row for `{execution_id, ordinal}`, after it fired or was consumed."
  @spec drop_timer(t(), execution_id(), ordinal()) :: :ok
  def drop_timer(ledger, execution_id, ordinal) do
    Agent.update(ledger, fn state ->
      update_in(state.timers, &Map.delete(&1, {execution_id, ordinal}))
    end)
  end

  @doc "Every open timer row for `execution_id`, oldest ordinal first."
  @spec open_timers(t(), execution_id()) :: [timer_row()]
  def open_timers(ledger, execution_id) do
    Agent.get(ledger, fn state ->
      state.timers
      |> Enum.filter(fn {{r, _ordinal}, _row} -> r == execution_id end)
      |> Enum.sort_by(fn {{_r, ordinal}, _row} -> ordinal end)
      |> Enum.map(fn {_key, row} -> row end)
    end)
  end

  @doc """
  Records an invocation as `:open`, idempotent on `{execution_id, invoke_id}`. A
  second call under the same key (`recover/1` re-running `handler.start/2`)
  leaves the stored row and the `side_effects` log untouched - the ledger,
  not the handler, is what makes re-establishment idempotent.
  """
  @spec record_invocation(t(), execution_id(), %{
          invoke_id: String.t(),
          type: term(),
          params: term()
        }) ::
          :ok
  def record_invocation(ledger, execution_id, %{invoke_id: invoke_id} = attrs) do
    key = {execution_id, invoke_id}

    Agent.update(ledger, fn state ->
      if Map.has_key?(state.invocations, key) do
        state
      else
        row = Map.put(attrs, :status, :open)

        state
        |> put_in([:invocations, key], row)
        |> append_side_effect({:record_invocation, key})
      end
    end)
  end

  @doc "Marks the invocation under `{execution_id, invoke_id}` `:done`. A no-op when no such row exists."
  @spec close_invocation(t(), execution_id(), String.t()) :: :ok
  def close_invocation(ledger, execution_id, invoke_id) do
    key = {execution_id, invoke_id}

    Agent.update(ledger, fn state ->
      update_in(state.invocations[key], fn
        nil -> nil
        row -> %{row | status: :done}
      end)
    end)
  end

  @doc "Every `:open` invocation row for `execution_id`, sorted by `invoke_id`."
  @spec open_invocations(t(), execution_id()) :: [invocation_row()]
  def open_invocations(ledger, execution_id) do
    Agent.get(ledger, fn state ->
      state.invocations
      |> Enum.filter(fn {{r, _id}, row} -> r == execution_id and row.status == :open end)
      |> Enum.sort_by(fn {{_r, invoke_id}, _row} -> invoke_id end)
      |> Enum.map(fn {_key, row} -> row end)
    end)
  end

  @doc "Appends `{effect, context}` to the executor call log, in call order."
  @spec record_call(t(), Statifier.Effect.t(), StatifierPersistence.Executor.context()) :: :ok
  def record_call(ledger, effect, context) do
    Agent.update(ledger, fn state ->
      %{state | executor_calls: [{effect, context} | state.executor_calls]}
    end)
  end

  @doc "Every recorded `{effect, context}` call, oldest first."
  @spec calls(t()) :: [{Statifier.Effect.t(), StatifierPersistence.Executor.context()}]
  def calls(ledger) do
    Agent.get(ledger, fn state -> Enum.reverse(state.executor_calls) end)
  end

  @doc """
  Appends `key` to the idempotency ledger, but only the first time it is
  seen - the mechanism `arm_timer/3` and `record_invocation/3` share.
  """
  @spec record_side_effect(t(), side_effect_key()) :: :ok
  def record_side_effect(ledger, key) do
    Agent.update(ledger, &append_side_effect(&1, key))
  end

  @doc "Every recorded side-effect key, oldest first, one entry per genuinely new key."
  @spec side_effects(t()) :: [side_effect_key()]
  def side_effects(ledger) do
    Agent.get(ledger, fn state -> Enum.reverse(state.side_effects) end)
  end

  @spec append_side_effect(state(), side_effect_key()) :: state()
  defp append_side_effect(state, key) do
    if key in state.side_effects do
      state
    else
      %{state | side_effects: [key | state.side_effects]}
    end
  end
end
