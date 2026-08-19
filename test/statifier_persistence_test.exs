defmodule StatifierPersistenceTest do
  use ExUnit.Case

  # sabotage: n/a - scaffold placeholder asserting only that the module loads;
  # replaced by real tests with the first behaviour
  test "the scaffold module loads" do
    assert {:module, StatifierPersistence} = Code.ensure_loaded(StatifierPersistence)
  end
end
