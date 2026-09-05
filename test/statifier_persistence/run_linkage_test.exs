defmodule StatifierPersistence.RunLinkageTest do
  @moduledoc """
  `StatifierPersistence.Run.Linkage` (Phase 2): the reserved metadata
  namespace, the child run id derivation, the two match maps, and the
  no-linkage arm.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.Run.Linkage

  describe "to_metadata/1 and from_metadata/1" do
    # sabotage: from_metadata/1 returns {:ok, %Linkage{}} built from
    # hardcoded defaults regardless of what to_metadata/1 stored -> red,
    # this round-trip's asserted values would not equal the original
    # linkage's. Verified red, reverted.
    test "round-trips a linkage through the reserved namespace" do
      linkage = Linkage.new("run_parent", "call", 0, "sha256:abc")

      metadata = Linkage.to_metadata(linkage)

      assert metadata == %{
               "statifier_persistence" => %{
                 "parent_run_id" => "run_parent",
                 "invoke_id" => "call",
                 "child_index" => 0,
                 "content_hash" => "sha256:abc"
               }
             }

      assert {:ok, ^linkage} = Linkage.from_metadata(metadata)
    end

    # sabotage: from_metadata/1's case returns {:ok, new(...)} unconditionally
    # instead of :no_linkage on the fallback arm -> red, this returned {:ok, _}
    # for metadata with no reserved key at all. Verified red, reverted.
    test "answers :no_linkage for metadata with no reserved key" do
      assert :no_linkage = Linkage.from_metadata(%{})
    end

    # sabotage: same rewrite as the round-trip test's mutation above (a
    # constant {:ok, %Linkage{}} regardless of input) -> red, this returned
    # {:ok, _} for a host map that carries no reserved key at all. Verified
    # red, reverted.
    test "answers :no_linkage for a host map with unrelated keys" do
      assert :no_linkage = Linkage.from_metadata(%{"tenant_id" => "acct_1"})
    end
  end

  describe "child_run_id/3" do
    # sabotage: child_run_id/3 returns "child" regardless of its arguments
    # -> red, both the stability and the differs-on-any-input assertions
    # below failed. Verified red, reverted.
    test "is stable for the same inputs and differs when any input differs" do
      id = Linkage.child_run_id("run_parent", "call", 0)

      assert Linkage.child_run_id("run_parent", "call", 0) == id
      refute Linkage.child_run_id("run_other", "call", 0) == id
      refute Linkage.child_run_id("run_parent", "other_call", 0) == id
      refute Linkage.child_run_id("run_parent", "call", 1) == id
    end

    # sabotage: child_run_id/3 returns "child" regardless of its arguments
    # -> red, both assertions below failed. Verified red, reverted.
    test "strictly starts with the parent id (the cascade's acyclicity property)" do
      id = Linkage.child_run_id("run_parent", "call", 0)

      assert String.starts_with?(id, "run_parent")
      refute id == "run_parent"
    end
  end

  describe "parent_match/1 and invocation_match/2" do
    # sabotage: parent_match/1's inner map key changed from "parent_run_id"
    # to "WRONG_KEY" -> red, the assertion below failed on the mismatched
    # key. Verified red, reverted.
    test "parent_match/1 is a containment map on parent_run_id alone" do
      assert Linkage.parent_match("run_parent") == %{
               "statifier_persistence" => %{"parent_run_id" => "run_parent"}
             }
    end

    # sabotage: invocation_match/2 dropped the "invoke_id" pair from the
    # inner map (ignored the invoke_id argument) -> red, the returned map
    # was narrowed to parent_run_id alone instead of both keys. Verified
    # red, reverted.
    test "invocation_match/2 narrows to one invocation" do
      assert Linkage.invocation_match("run_parent", "call") == %{
               "statifier_persistence" => %{
                 "parent_run_id" => "run_parent",
                 "invoke_id" => "call"
               }
             }
    end
  end

  describe "the fan-out values (sp-t57)" do
    # sabotage: to_metadata/1's fan_out_metadata/1 nil clause returns the
    # two keys with nil values instead of %{} -> red, this map carried
    # "child_count" => nil and "policy" => nil beside the four. Verified
    # red, reverted.
    test "a non-fan-out linkage stores exactly the four keys it always has" do
      linkage = Linkage.new("run_parent", "call", 0, "sha256:abc")

      assert Linkage.to_metadata(linkage) == %{
               "statifier_persistence" => %{
                 "parent_run_id" => "run_parent",
                 "invoke_id" => "call",
                 "child_index" => 0,
                 "content_hash" => "sha256:abc"
               }
             }

      refute Linkage.fan_out?(linkage)
    end

    # sabotage: fan_out_metadata/1 stored the policy atom rather than its
    # string spelling -> red, the asserted map's "policy" was :all instead
    # of "all", which is also not JSON-representable. Verified red,
    # reverted.
    test "a fan-out linkage round-trips both values through the reserved map" do
      linkage = Linkage.new("run_parent", "call", 2, "sha256:abc", 3, :first_error)

      metadata = Linkage.to_metadata(linkage)

      assert metadata == %{
               "statifier_persistence" => %{
                 "parent_run_id" => "run_parent",
                 "invoke_id" => "call",
                 "child_index" => 2,
                 "content_hash" => "sha256:abc",
                 "child_count" => 3,
                 "policy" => "first_error"
               }
             }

      assert {:ok, ^linkage} = Linkage.from_metadata(metadata)
      assert Linkage.fan_out?(linkage)
    end

    # sabotage: fan_out?/1's nil clause returns true -> red, the N=1 case
    # below still passed but the non-fan-out assertion in the first test of
    # this block failed. Verified red, reverted.
    test "child_count: 1 is the N=1 fan-out, not a non-fan-out" do
      linkage = Linkage.new("run_parent", "call", 0, "sha256:abc", 1, :all)

      assert Linkage.fan_out?(linkage)
      assert linkage.child_count == 1
      assert linkage.policy == :all
    end

    # sabotage: new/6's child_index bound check compared against
    # child_count + 1 -> red, index 3 of 3 was accepted instead of raising.
    # Verified red, reverted.
    test "new/6 refuses an index outside 0..child_count - 1" do
      assert_raise ArgumentError, fn ->
        Linkage.new("run_parent", "call", 3, "sha256:abc", 3, :all)
      end
    end

    # sabotage: build/5's `_one_without_the_other` arm was changed to build
    # a non-fan-out linkage instead of answering :no_linkage -> red, the
    # first two assertions below returned {:ok, _}. Verified red, reverted.
    test "a malformed fan-out half answers :no_linkage" do
      assert :no_linkage = Linkage.from_metadata(reserved(%{"child_count" => 3}))
      assert :no_linkage = Linkage.from_metadata(reserved(%{"policy" => "all"}))

      assert :no_linkage =
               Linkage.from_metadata(reserved(%{"child_count" => 0, "policy" => "all"}))

      assert :no_linkage =
               Linkage.from_metadata(reserved(%{"child_count" => 3, "policy" => "some"}))

      assert :no_linkage =
               Linkage.from_metadata(reserved(%{"child_count" => 2, "policy" => "all"}))
    end
  end

  # The reserved map with `child_index` 2, plus whatever the case under
  # test adds: index 2 is inside a count of 3 and outside a count of 2,
  # which is what the last malformed case above turns on.
  defp reserved(extra) do
    %{
      "statifier_persistence" =>
        Map.merge(
          %{
            "parent_run_id" => "run_parent",
            "invoke_id" => "call",
            "child_index" => 2,
            "content_hash" => "sha256:abc"
          },
          extra
        )
    }
  end
end
