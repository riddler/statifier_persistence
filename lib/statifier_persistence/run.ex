defmodule StatifierPersistence.Run do
  @moduledoc """
  The host-facing view of a durable run: what state is this run in - never
  what its bytes are. The position blob stays on the stored record
  (ADR-0004 decision 1), loaded only through the guarded
  `StatifierPersistence.Storage.load_run_position/3` path; this struct
  carries the fields a host reads to decide what to do with a run.
  """

  alias StatifierPersistence.Storage.Adapter

  @enforce_keys [:run_id, :status, :content_hash]
  defstruct [:run_id, :status, :content_hash, :failure, :donedata]

  @type t :: %__MODULE__{
          run_id: Adapter.run_id(),
          status: Adapter.run_status(),
          content_hash: Adapter.content_hash(),
          failure: String.t() | nil,
          donedata: term() | nil
        }

  @doc """
  Builds the host-facing struct from a stored
  `t:StatifierPersistence.Storage.Adapter.run_record/0`, dropping the two
  blob fields (`identity_blob`, `position_blob`) and carrying everything
  else verbatim.

  `donedata` is always `nil` here: a stored record carries no donedata
  (ADR-0008 decision 3) - a position that has reached a final state has no
  configuration left to carry it, so it exists only on the step that
  produced it, via `StatifierPersistence.Runs`' own construction of this
  struct.
  """
  @spec from_record(Adapter.run_record()) :: t()
  def from_record(%{
        run_id: run_id,
        status: status,
        content_hash: content_hash,
        failure: failure
      }) do
    %__MODULE__{
      run_id: run_id,
      status: status,
      content_hash: content_hash,
      failure: failure,
      donedata: nil
    }
  end
end
