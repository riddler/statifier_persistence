defmodule StatifierPersistence.Storage.InMemoryTest do
  use ExUnit.Case

  alias StatifierPersistence.Storage.InMemory

  setup do
    {:ok, opts} = InMemory.init([])
    {:ok, opts: opts}
  end

  # sabotage: save_chart/2 stores under a fixed key instead of content_hash -> red
  test "round-trips a saved chart", %{opts: opts} do
    chart_record = %{
      content_hash: "sha256:abc",
      identity_blob: <<1, 2, 3>>,
      chart_blob: <<4, 5, 6>>
    }

    assert :ok = InMemory.save_chart(opts, chart_record)
    assert {:ok, ^chart_record} = InMemory.fetch_chart(opts, "sha256:abc")
  end

  # sabotage: save_chart/2 appends instead of overwriting on a repeat hash -> red
  test "save_chart/2 is idempotent on a repeated content_hash", %{opts: opts} do
    chart_record = %{
      content_hash: "sha256:abc",
      identity_blob: <<1, 2, 3>>,
      chart_blob: <<4, 5, 6>>
    }

    assert :ok = InMemory.save_chart(opts, chart_record)
    assert :ok = InMemory.save_chart(opts, chart_record)
    assert {:ok, ^chart_record} = InMemory.fetch_chart(opts, "sha256:abc")
  end

  # sabotage: fetch_chart/2 returns {:ok, nil} instead of :chart_not_found -> red
  test "fetch_chart/2 reports :chart_not_found for an unknown hash", %{opts: opts} do
    assert {:error, :chart_not_found} = InMemory.fetch_chart(opts, "sha256:missing")
  end

  # sabotage: save_position/2 stores under a fixed key instead of session_id -> red
  test "round-trips a saved position", %{opts: opts} do
    position_record = %{
      session_id: "sess_abc",
      content_hash: "sha256:abc",
      identity_blob: <<1, 2, 3>>,
      position_blob: <<7, 8, 9>>
    }

    assert :ok = InMemory.save_position(opts, position_record)
    assert {:ok, ^position_record} = InMemory.fetch_position(opts, "sess_abc")
  end

  # sabotage: save_position/2 merges instead of overwriting a prior position -> red
  test "save_position/2 overwrites a prior position for the same session_id", %{opts: opts} do
    first = %{
      session_id: "sess_abc",
      content_hash: "sha256:abc",
      identity_blob: <<1, 2, 3>>,
      position_blob: <<7, 8, 9>>
    }

    second = %{
      session_id: "sess_abc",
      content_hash: "sha256:def",
      identity_blob: <<10, 11, 12>>,
      position_blob: <<13, 14, 15>>
    }

    assert :ok = InMemory.save_position(opts, first)
    assert :ok = InMemory.save_position(opts, second)
    assert {:ok, ^second} = InMemory.fetch_position(opts, "sess_abc")
  end

  # sabotage: fetch_position/2 returns {:ok, nil} instead of :position_not_found -> red
  test "fetch_position/2 reports :position_not_found for an unknown session_id", %{opts: opts} do
    assert {:error, :position_not_found} = InMemory.fetch_position(opts, "sess_missing")
  end
end
