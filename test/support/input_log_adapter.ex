defmodule StatifierPersistence.Test.InputLogAdapter do
  @moduledoc """
  A delegating `StatifierPersistence.Storage.Adapter` wrapping
  `StatifierPersistence.Storage.InMemory` that adds ADR-0010's input log:
  `supports_input_log?/1`, `append_input/3` and `list_inputs/2` over an
  Agent of its own.

  `StatifierPersistence.Storage.InMemory` is deliberately not the place
  for this. ADR-0010 decision 1 names it as the adapter that stays
  conformant without a line of change, and the conformance suite needs an
  adapter that exports none of the three callbacks to prove the "an
  adapter without them skips the cases" half of the contract - `InMemory`
  is that adapter. This one is its opposite number, so the input-log cases
  execution without a database beside the Ecto adapter that runs them with one.

  The cap comes from `init/1`'s `input_log_cap:` option, exactly as it
  does on `StatifierPersistence.Storage.Ecto` (ADR-0010 decision 6):
  `:infinity` by default, a positive integer to bound the log.

  Test-only support code.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage.Adapter
  alias StatifierPersistence.Storage.InMemory

  @impl true
  @spec init(Adapter.opts()) :: {:ok, Adapter.opts()} | {:error, Adapter.error()}
  def init(opts) do
    cap = validate_cap!(Keyword.get(opts, :input_log_cap, :infinity))

    with {:ok, opts} <- InMemory.init(opts),
         {:ok, log_pid} <- Agent.start_link(fn -> %{} end) do
      {:ok, Keyword.merge(opts, log_pid: log_pid, input_log_cap: cap)}
    else
      {:error, reason} -> {:error, {:adapter, reason}}
    end
  end

  @impl true
  defdelegate save_chart(opts, chart_record), to: InMemory

  @impl true
  defdelegate fetch_chart(opts, content_hash), to: InMemory

  @impl true
  defdelegate save_position(opts, position_record), to: InMemory

  @impl true
  defdelegate fetch_position(opts, session_id), to: InMemory

  @impl true
  defdelegate insert_execution(opts, execution_record), to: InMemory

  @impl true
  defdelegate fetch_execution(opts, execution_id), to: InMemory

  @impl true
  defdelegate update_execution(opts, execution_record), to: InMemory

  @impl true
  defdelegate supports_metadata?(opts), to: InMemory

  @impl true
  defdelegate list_executions_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate list_execution_states_by_metadata(opts, metadata), to: InMemory

  @impl true
  defdelegate supports_execution_outcome?(opts), to: InMemory

  @impl true
  defdelegate lock_execution(opts, execution_id, fun), to: InMemory

  @impl true
  @spec supports_input_log?(Adapter.opts()) :: boolean()
  def supports_input_log?(_opts), do: true

  @doc """
  Appends one input at the next ordinal, or closes the log with a marker
  and refuses once the cap's last slot is reached (ADR-0010 decision 6).

  The whole read-modify-write runs inside `Agent.get_and_update/2`, which
  is this adapter's stand-in for the exclusion a database gives the Ecto
  adapter through its unique index: the ordinal cannot be handed out
  twice.
  """
  @impl true
  @spec append_input(Adapter.opts(), Adapter.execution_id(), Adapter.input_record()) ::
          {:ok, Adapter.seq()} | {:error, Adapter.error()}
  def append_input(opts, execution_id, %{door: door, input_blob: input_blob}) do
    cap = Keyword.fetch!(opts, :input_log_cap)

    Agent.get_and_update(log_pid(opts), fn logs ->
      entries = Map.get(logs, execution_id, [])

      case slot(entries, cap) do
        {:closed, _seq} ->
          {{:error, :input_log_full}, logs}

        {:marker, seq} ->
          record = %{execution_id: execution_id, seq: seq, door: door, input_blob: nil}
          {{:error, :input_log_full}, Map.put(logs, execution_id, entries ++ [record])}

        {:open, seq} ->
          record = %{execution_id: execution_id, seq: seq, door: door, input_blob: input_blob}
          {{:ok, seq}, Map.put(logs, execution_id, entries ++ [record])}
      end
    end)
  end

  @doc """
  Lists `execution_id`'s whole log in ascending `seq`, or `:execution_not_found` for a
  execution this adapter never stored.
  """
  @impl true
  @spec list_inputs(Adapter.opts(), Adapter.execution_id()) ::
          {:ok, [Adapter.input_record()]} | {:error, Adapter.error()}
  def list_inputs(opts, execution_id) do
    with {:ok, _execution_record} <- InMemory.fetch_execution(opts, execution_id) do
      {:ok, Agent.get(log_pid(opts), &Map.get(&1, execution_id, []))}
    end
  end

  # The three states the next append can be in: the log already carries a
  # closed marker in its last slot, this append IS the last slot the cap
  # admits, or there is room.
  @spec slot([Adapter.input_record()], pos_integer() | :infinity) ::
          {:closed | :marker | :open, Adapter.seq()}
  defp slot(entries, cap) do
    seq = length(entries)

    cond do
      match?(%{input_blob: nil}, List.last(entries)) -> {:closed, seq}
      cap == :infinity -> {:open, seq}
      seq >= cap - 1 -> {:marker, seq}
      true -> {:open, seq}
    end
  end

  @spec log_pid(Adapter.opts()) :: pid()
  defp log_pid(opts), do: Keyword.fetch!(opts, :log_pid)

  @spec validate_cap!(term()) :: pos_integer() | :infinity
  defp validate_cap!(:infinity), do: :infinity
  defp validate_cap!(cap) when is_integer(cap) and cap > 0, do: cap

  defp validate_cap!(other) do
    raise ArgumentError,
          "the :input_log_cap option must be a positive integer or :infinity, " <>
            "got: #{inspect(other)}"
  end
end
