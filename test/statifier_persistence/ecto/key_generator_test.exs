defmodule StatifierPersistence.Ecto.KeyGeneratorTest do
  use ExUnit.Case, async: true

  alias StatifierPersistence.Ecto.KeyGenerator

  defmodule NotAGenerator do
    @moduledoc false
  end

  describe "resolve/1" do
    # sabotage: resolve(:uuid) returns the UXID module -> red (match on UUIDv7)
    test "maps ADR-0002's atom spellings onto the bundled implementations" do
      assert {KeyGenerator.UXID, []} = KeyGenerator.resolve(:uxid)
      assert {KeyGenerator.UUIDv7, []} = KeyGenerator.resolve(:uuid)
      assert {KeyGenerator.Bigserial, []} = KeyGenerator.resolve(:bigserial)
    end

    # sabotage: resolve({module, opts}) returns {module, []} -> red (opts dropped)
    test "passes {module, opts} through when the module implements the behaviour" do
      assert {KeyGenerator.UXID, [rand_size: 5]} =
               KeyGenerator.resolve({KeyGenerator.UXID, [rand_size: 5]})
    end

    # sabotage: implements_behaviour? check short-circuited to true -> red (nothing raised)
    test "refuses a module that does not implement the behaviour" do
      assert_raise ArgumentError, ~r/does not implement the .*KeyGenerator behaviour/, fn ->
        KeyGenerator.resolve({NotAGenerator, []})
      end
    end

    # sabotage: catch-all resolve/1 returns {UXID, []} instead of raising -> red (nothing raised)
    test "refuses an unknown spelling" do
      assert_raise ArgumentError, ~r/expected :uxid, :uuid, :bigserial/, fn ->
        KeyGenerator.resolve(:ulid)
      end
    end
  end

  describe "UXID" do
    # sabotage: UXID.ecto_type/1 returns :binary_id -> red (match on :string)
    test "declares :string schema fields over :text columns" do
      assert :string = KeyGenerator.UXID.ecto_type([])
      assert :text = KeyGenerator.UXID.migration_type([])
    end

    # sabotage: @prefixes positions entry changed to "position" -> red (expects "pos_")
    test "keys carry the per-table prefix" do
      for {table, prefix} <- [charts: "chart_", positions: "pos_", runs: "run_"] do
        {mod, fun, args} = KeyGenerator.UXID.autogenerate(table, [])
        key = apply(mod, fun, args)
        assert String.starts_with?(key, prefix)
      end
    end

    # sabotage: autogenerate/2 forces from: "fixed" (deterministic UXIDs) -> red (first == second)
    test "keys are k-sortable in generation order" do
      {mod, fun, args} = KeyGenerator.UXID.autogenerate(:runs, [])
      first = apply(mod, fun, args)
      # UXID timestamps have millisecond resolution; cross a boundary.
      Process.sleep(2)
      second = apply(mod, fun, args)
      assert first < second
    end
  end

  describe "UUIDv7" do
    # sabotage: UUIDv7.migration_type/1 returns :binary -> red (match on :uuid)
    test "declares Ecto.UUID schema fields over :uuid columns" do
      assert Ecto.UUID = KeyGenerator.UUIDv7.ecto_type([])
      assert :uuid = KeyGenerator.UUIDv7.migration_type([])
    end

    # sabotage: generate/0 writes version nibble 4 instead of 7 -> red (version match fails)
    test "generates valid UUID strings with version 7 and variant 10" do
      {mod, fun, args} = KeyGenerator.UUIDv7.autogenerate(:charts, [])
      uuid = apply(mod, fun, args)

      assert {:ok, _raw} = Ecto.UUID.dump(uuid)

      assert <<_::binary-size(14), "7", _::binary-size(3), "-", variant::binary-size(1),
               _::binary>> = uuid

      assert variant in ~w(8 9 a b)
    end

    # sabotage: generate/0 inverts the 48-bit timestamp -> red (first > second)
    test "keys sort by generation time across a millisecond boundary" do
      first = KeyGenerator.UUIDv7.generate()
      Process.sleep(2)
      second = KeyGenerator.UUIDv7.generate()
      assert first < second
    end
  end

  describe "Bigserial" do
    # sabotage: Bigserial.ecto_type/1 returns :integer -> red (match on :id)
    test "declares :id schema fields over :bigserial columns" do
      assert :id = KeyGenerator.Bigserial.ecto_type([])
      assert :bigserial = KeyGenerator.Bigserial.migration_type([])
    end

    # sabotage: Bigserial.autogenerate/2 returns an MFA -> red (expects nil)
    test "declares database-assigned keys for every table" do
      for table <- [:charts, :positions, :runs] do
        assert nil == KeyGenerator.Bigserial.autogenerate(table, [])
      end
    end
  end
end
