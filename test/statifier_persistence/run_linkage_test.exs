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
end
