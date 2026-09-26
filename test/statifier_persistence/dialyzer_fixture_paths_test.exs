defmodule StatifierPersistence.DialyzerFixturePathsTest do
  @moduledoc """
  Holds `test/dialyzer/` in the `:dev` compile paths.

  `mix dialyzer` analyses the modules of the environment it runs in, which
  is `:dev`, so the fixture there is read by the gate's Dialyzer stage only
  while `elixirc_paths/1` in `mix.exs` compiles it for `:dev`. Dropped from
  that list, the fixture would silently stop being read and the Dialyzer
  stage would stay green on nothing. This test reads the project config as
  `:dev` builds it and fails when the directory is missing from it.
  """

  # Not async: the check sets `Mix.env/1` for the length of one call to
  # `project/0`, and `Mix.env/0` is global to the VM.
  use ExUnit.Case, async: false

  @fixture_dir "test/dialyzer"

  defp elixirc_paths_for(env) do
    previous = Mix.env()
    Mix.env(env)

    try do
      Keyword.fetch!(StatifierPersistence.MixProject.project(), :elixirc_paths)
    after
      Mix.env(previous)
    end
  end

  test "the Dialyzer fixture directory holds source files" do
    assert [_ | _] = Path.wildcard(Path.join(@fixture_dir, "**/*.ex"))
  end

  # sabotage: elixirc_paths(:dev) in mix.exs without "test/dialyzer" -> red
  test "the :dev compile paths include the Dialyzer fixture directory" do
    assert @fixture_dir in elixirc_paths_for(:dev)
  end
end
