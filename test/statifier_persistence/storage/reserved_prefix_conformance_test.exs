defmodule StatifierPersistence.Storage.ReservedPrefixConformanceTest do
  @moduledoc """
  The reserved-prefix contract in
  `StatifierPersistence.Testing.StorageConformance`'s moduledoc, under
  test.

  Every name the suite's `use` defines in a host module carries the
  `conformance` prefix, so a host is free to keep every other name for
  itself. This module is the host-shaped case: it keeps an attribute, a
  nested module and a private function of its own under names the suite
  once defined without the prefix, and the suite's own cases run beside
  them against `StatifierPersistence.Storage.InMemory`, which exports every
  optional callback those names were generated under.
  """

  # The host's own attribute, set above the `use`.
  @retire_hash "sha256:the-host-module-own-hash"

  # The host's own nested module, defined above the `use`.
  defmodule ReentrantSerialization do
    @moduledoc false

    @spec owner() :: :host
    def owner, do: :host
  end

  use StatifierPersistence.Testing.StorageConformance,
    async: true,
    adapter: StatifierPersistence.Storage.InMemory,
    opts: []

  # sabotage: in the template, rename `@conformance_retire_hash` back to
  # `@retire_hash` -> red, the attribute read here answers the suite's
  # retire hash instead of the host's own. Verified red, reverted.
  test "a host attribute named like a suite attribute keeps the host's value" do
    assert @retire_hash == "sha256:the-host-module-own-hash"
  end

  # sabotage: in the template, rename `ConformanceReentrantSerialization`
  # back to `ReentrantSerialization` -> red, the suite's module replaces
  # the host's and `owner/0` is gone. Verified red, reverted.
  test "a host nested module named like a suite module keeps the host's functions" do
    assert function_exported?(ReentrantSerialization, :owner, 0)
  end

  # sabotage: in the template, rename `conformance_own_chart_a/0` back to
  # `own_chart_a/0` -> red, the suite's clause comes first and answers
  # its own chart instead of the host's atom. Verified red, reverted.
  test "a host private function named like a suite helper keeps the host's body" do
    assert own_chart_a() == :the_host_module_own_chart
  end

  # The host's own private helper, defined below the `use`.
  defp own_chart_a, do: :the_host_module_own_chart
end
