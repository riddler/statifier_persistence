defmodule StatifierPersistence.ExecutionsOptTypesTest do
  @moduledoc """
  The option types `StatifierPersistence.Executions.create/4` and
  `step/5` name in their specs, read from the compiled module's typespecs.

  Each function's type lists the options that function reads and no
  other, so Dialyzer reports an option passed to the door that ignores
  it. The case that made this matter: `send_types:` given to `create/4`
  at the top level is never read - on a create it has to travel inside
  `initialize:` - and while one union served both functions that call
  type-checked.
  """

  use ExUnit.Case, async: true

  alias StatifierPersistence.Executions

  # sabotage: added `| {:send_types, MachineState.send_types()}` to
  # `t:create_opt/0` -> red, the create set gained `:send_types`.
  # Verified red, reverted.
  test "create/4's option type lists exactly the options create/4 reads" do
    assert option_keys(:create_opt) ==
             MapSet.new([
               :executor,
               :initialize,
               :metadata,
               :linkage,
               :serialization,
               :step_reporter
             ])
  end

  # sabotage: added `| {:initialize, keyword()}` to `t:step_opt/0` ->
  # red, the step set gained `:initialize`. Verified red, reverted.
  test "step/5's option type lists exactly the options step/5 reads" do
    assert option_keys(:step_opt) ==
             MapSet.new([
               :executor,
               :routes,
               :invoke_types,
               :send_types,
               :serialization,
               :entry,
               :invoke_id,
               :child_count,
               :step_reporter
             ])
  end

  # sabotage: the same `:send_types` arm added to `t:create_opt/0` -> red,
  # the two sets were no longer disjoint. Verified red, reverted.
  test "the options a create ignores are absent from create/4's type" do
    ignored = MapSet.new([:routes, :invoke_types, :send_types, :entry])

    assert MapSet.disjoint?(option_keys(:create_opt), ignored)
  end

  # sabotage: pointed `create/4`'s `opts` back at `[opt()]` -> red, the
  # spec named `:opt`. Verified red, reverted.
  test "each function's spec names its own option type" do
    assert opts_type(:create, 4) == :create_opt
    assert opts_type(:step, 5) == :step_opt
  end

  # sabotage: `t:opt/0` written as `create_opt()` alone -> red, the
  # step-only keys were missing. Verified red, reverted.
  test "t:opt/0 stays the union of the two" do
    assert option_keys(:opt) ==
             MapSet.union(option_keys(:create_opt), option_keys(:step_opt))
  end

  # The keys of a `{key, value}` union type, following a union arm that
  # names another local type (`t:opt/0` is written over the other two).
  defp option_keys(name) do
    {:ok, types} = Code.Typespec.fetch_types(Executions)
    keys_of(types, name)
  end

  defp keys_of(types, name) do
    {_kind, {^name, ast, []}} =
      Enum.find(types, &match?({kind, {^name, _ast, []}} when kind in [:type, :opaque], &1))

    ast |> arms() |> Enum.reduce(MapSet.new(), &arm_keys(types, &1, &2))
  end

  defp arms({:type, _line, :union, arms}), do: arms
  defp arms(single), do: [single]

  defp arm_keys(_types, {:type, _line, :tuple, [{:atom, _, key}, _value]}, acc),
    do: MapSet.put(acc, key)

  defp arm_keys(types, {:user_type, _line, name, []}, acc),
    do: MapSet.union(acc, keys_of(types, name))

  # The element type of the last argument's list, as the name of the
  # local type it refers to.
  defp opts_type(fun, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(Executions)

    {{^fun, ^arity}, [{:type, _, :fun, [{:type, _, :product, args}, _return]}]} =
      Enum.find(specs, &match?({{^fun, ^arity}, _}, &1))

    case List.last(args) do
      {:ann_type, _, [_name, {:type, _, :list, [{:user_type, _, type, []}]}]} -> type
      {:type, _, :list, [{:user_type, _, type, []}]} -> type
    end
  end
end
