defmodule StatifierPersistenceTest do
  use ExUnit.Case

  # sabotage: version/0 returns a literal instead of the app spec -> red
  test "version/0 reports the package version from the app spec" do
    assert StatifierPersistence.version() == Mix.Project.config()[:version]
  end
end
