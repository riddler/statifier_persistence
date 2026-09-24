defmodule StatifierPersistence.SandboxModeTest do
  use ExUnit.Case, async: true

  # The SQL sandbox mode is a property of the one shared TestRepo, not of the
  # module that sets it: a module that switches the repo away from :manual
  # (to :auto, or to a shared owner) changes it for every test running at
  # that moment. What keeps such a switch inside its own module is ExUnit's
  # ordering: it runs every async module first, and only after all of them
  # have finished runs the synchronous modules, one at a time. A module that
  # leaves :manual is therefore safe only while it is not `async: true`.
  #
  # This test reads the suite's own source and holds that line: every test
  # file that sets a sandbox mode other than :manual must not be async.
  # test/test_helper.exs says the same in prose.

  @mode_call ~r/Sandbox\.mode\(\s*[\w.]+\s*,\s*(?!:manual\b)[^)\s]/
  @async_true ~r/\basync:\s*true\b/

  defp test_files do
    "test/**/*_test.exs"
    |> Path.wildcard()
    |> Enum.reject(&(&1 == __ENV__.file |> Path.relative_to_cwd()))
    |> Enum.sort()
  end

  defp leaves_manual?(source), do: Regex.match?(@mode_call, source)

  test "the mode pattern matches a switch away from :manual and not the restore" do
    assert leaves_manual?("Sandbox.mode(TestRepo, :auto)")
    assert leaves_manual?("Sandbox.mode(StatifierPersistence.TestRepo, {:shared, self()})")
    refute leaves_manual?("Sandbox.mode(TestRepo, :manual)")
    refute leaves_manual?("Sandbox.checkout(TestRepo)")
  end

  # sabotage: change held_lease_test.exs to `use ExUnit.Case, async: true`
  # -> red, naming that file (verified, restored from a copy).
  test "no test module that leaves the :manual sandbox mode runs async" do
    leaving = for file <- test_files(), leaves_manual?(File.read!(file)), do: file

    # A pattern that stopped matching would pass the check below on nothing.
    assert leaving != [], "no test file sets a non-:manual sandbox mode; is @mode_call stale?"

    assert [] == Enum.filter(leaving, &Regex.match?(@async_true, File.read!(&1)))
  end
end
