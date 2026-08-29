defmodule StatifierPersistence.Storage.EctoBlobTypeTest do
  @moduledoc """
  Proves `:blob_type` (`StatifierPersistence.Ecto.Config`, sp-km3) is
  really applied on write and read, not silently bypassed. The
  conformance suite (`EctoBlobTypeConformanceTest`) only proves the
  round trip is byte-identical through the adapter; a no-op type would
  pass that too. This module reads the raw column with `repo.query!`,
  bypassing the schema entirely, to prove the stored bytes differ from
  the input and equal the transform of the input.
  """

  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.Ecto.Config
  alias StatifierPersistence.EctoHosts.BlobTyped
  alias StatifierPersistence.Storage
  alias StatifierPersistence.Test.ReversibleBlobType
  alias StatifierPersistence.TestRepo

  setup do
    :ok = Sandbox.checkout(TestRepo)
    {:ok, opts} = Storage.Ecto.init(persistence: BlobTyped)
    %{opts: opts}
  end

  # sabotage: swapped StatifierPersistence.Test.ReversibleBlobType for :binary
  # on the BlobTyped fixture host's blob_type -> red, both raw-column
  # assertions failed (stored bytes equalled the plaintext, so the
  # "differs from input" assertion failed first). Verified red, reverted.
  test "the raw chart_blob column is transformed, not plaintext", %{opts: opts} do
    identity_blob = <<10, 20, 30>>
    chart_blob = <<40, 50, 60, 70>>

    chart_record = %{
      content_hash: "sha256:blob-type-raw-chart",
      identity_blob: identity_blob,
      chart_blob: chart_blob
    }

    :ok = Storage.Ecto.save_chart(opts, chart_record)

    table = Config.table(BlobTyped.__statifier_persistence__(:config), :charts)

    %{rows: [[raw_identity, raw_chart]]} =
      TestRepo.query!(
        "SELECT identity_blob, chart_blob FROM #{table} WHERE content_hash = $1",
        [chart_record.content_hash]
      )

    assert raw_identity != identity_blob
    assert raw_chart != chart_blob
    assert raw_identity == ReversibleBlobType.transform(identity_blob)
    assert raw_chart == ReversibleBlobType.transform(chart_blob)

    assert {:ok, ^chart_record} = Storage.Ecto.fetch_chart(opts, chart_record.content_hash)
  end

  # sabotage: same as above, applied to save_position/2's schema instead
  # of save_chart/2's -> red for the identical reason. Verified red,
  # reverted.
  test "the raw position_blob column is transformed, not plaintext", %{opts: opts} do
    identity_blob = <<1, 1, 1>>
    position_blob = <<9, 9, 9, 9>>

    position_record = %{
      session_id: "sess_blob_type_raw",
      content_hash: "sha256:blob-type-raw-position",
      identity_blob: identity_blob,
      position_blob: position_blob
    }

    :ok = Storage.Ecto.save_position(opts, position_record)

    table = Config.table(BlobTyped.__statifier_persistence__(:config), :positions)

    %{rows: [[raw_identity, raw_position]]} =
      TestRepo.query!(
        "SELECT identity_blob, position_blob FROM #{table} WHERE session_id = $1",
        [position_record.session_id]
      )

    assert raw_identity != identity_blob
    assert raw_position != position_blob
    assert raw_identity == ReversibleBlobType.transform(identity_blob)
    assert raw_position == ReversibleBlobType.transform(position_blob)

    assert {:ok, ^position_record} =
             Storage.Ecto.fetch_position(opts, position_record.session_id)
  end
end
