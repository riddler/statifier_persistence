defmodule StatifierPersistence.Execution do
  @moduledoc """
  The host-facing view of a durable execution: what state is this execution in - never
  what its bytes are. The position blob stays on the stored record
  (ADR-0004 decision 1), loaded only through the guarded
  `StatifierPersistence.Storage.load_execution_position/3` path; this struct
  carries the fields a host reads to decide what to do with an execution.

  `ended_at` is the stamp the stored record carries (V08 of the
  migrations helper on the Ecto adapter): the time of the first terminal
  write the row received while it had no stamp, `nil` until then, and
  never moved or cleared once written.
  `StatifierPersistence.Executions.ended?/1` reads it, and says where the
  stamp and the status can disagree.
  """

  alias StatifierPersistence.Storage.Adapter

  @enforce_keys [:execution_id, :status, :content_hash]
  defstruct [:execution_id, :status, :content_hash, :failure, :donedata, :ended_at]

  @type t :: %__MODULE__{
          execution_id: Adapter.execution_id(),
          status: Adapter.execution_status(),
          content_hash: Adapter.content_hash(),
          failure: String.t() | nil,
          donedata: term() | nil,
          ended_at: DateTime.t() | nil
        }

  @doc """
  Builds the host-facing struct from a stored
  `t:StatifierPersistence.Storage.Adapter.execution_record/0`, dropping the two
  blob fields (`identity_blob`, `position_blob`) and carrying everything
  else verbatim. A record with no `ended_at` key - one from an adapter
  written before the field existed - builds a struct whose `ended_at` is
  `nil`.

  `donedata` is the execution's own recorded answer when the record carries
  one: the `donedata` of a `{:done, donedata}` answer in its `outcome_blob`,
  which `StatifierPersistence.Driver` records for a durable subchart's
  child: a fan-out child's by its settlement, a single child's before its
  parent's door is tried (ADR-0008's 2026-09-24 Amendment). It is `nil` for
  every other record: one with no recorded answer, which is every execution
  that is not such a child and every child that reached its terminal status
  before its answer was recorded, and one whose recorded answer is a
  failure. A position that has reached a final state has no configuration
  left to carry donedata, so the recorded answer is the only place a stored
  record keeps it.
  """
  @spec from_record(Adapter.execution_record()) :: t()
  def from_record(
        %{
          execution_id: execution_id,
          status: status,
          content_hash: content_hash,
          failure: failure
        } = record
      ) do
    %__MODULE__{
      execution_id: execution_id,
      status: status,
      content_hash: content_hash,
      failure: failure,
      donedata: donedata(Map.get(record, :outcome_blob)),
      ended_at: Map.get(record, :ended_at)
    }
  end

  # The recorded answer is `StatifierPersistence.Driver`'s encoding, the
  # `:erlang.term_to_binary/1` of `{:done, donedata}` or `{:failed,
  # failure}`; only the first carries donedata.
  @spec donedata(binary() | nil) :: term() | nil
  defp donedata(nil), do: nil

  defp donedata(outcome_blob) when is_binary(outcome_blob) do
    case :erlang.binary_to_term(outcome_blob) do
      {:done, donedata} -> donedata
      _failed -> nil
    end
  end
end
