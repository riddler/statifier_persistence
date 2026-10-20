defmodule MyApp.Holds do
  @moduledoc false

  # The host-side hold check the guide's executor calls and leaves to the
  # reader. The executor runs in the process that steps the execution, so
  # this stand-in reports the call to that process.
  @spec check(String.t(), String.t()) :: :ok
  def check(execution_id, invoke_id) do
    send(self(), {:hold_checked, execution_id, invoke_id})
    :ok
  end
end

defmodule StatifierPersistence.ReadmeExampleTest do
  @moduledoc """
  The guide "How to persist an execution and resume it in another process"
  (`docs/guides/persist-and-resume.md`), executed.

  This project has no doctests (the public functions take a live store, not
  values a doctest can print), so a snippet has nothing checking it but this
  file. The test reads the page, takes its `elixir` code blocks in order and
  evaluates each one, threading the bindings and aliases from block to
  block, then asserts every output the page claims after the block that
  claims it. The one host-side call the page leaves to the reader,
  `MyApp.Holds.check/2`, is the stand-in defined above.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Event, Machine, MachineState}
  alias StatifierPersistence.Executions

  @page "docs/guides/persist-and-resume.md"
  @title "# How to persist an execution and resume it in another process"

  # sabotage: made `execution_status/2` return `:active` where it returns `:completed`
  # for a `:done` machine state (executions.ex) - the final `execution.status == :completed`
  # assertion went red, and reverting brought it back.
  #
  # sabotage: changed the page's create call to pass `opts` (the
  # registrations beside `executor:`) in place of `initialize: stamps` -
  # `state.invoke_types` on the created position came back `nil` and its
  # assertion went red, because `create/4` reads only `initialize:`;
  # restoring the page's placement brought it back.
  test "the guide's loan is lent, resumed across a restart and returned" do
    page = File.read!(@page)
    assert hd(String.split(page, "\n", parts: 2)) == @title

    assert [
             define,
             store_chart,
             connect,
             create,
             first_step,
             restart,
             due_step,
             returned_step,
             read_back
           ] = elixir_blocks(page)

    acc = {[], Code.env_for_eval(file: @page)}

    acc = acc |> eval(define) |> eval(store_chart) |> eval(connect)
    stamps = fetch(acc, :stamps)

    acc = eval(acc, create)
    execution = fetch(acc, :execution)
    state = fetch(acc, :state)

    assert execution.status == :active
    assert config(state) == ["checking_holds"]
    assert_received {:hold_checked, "loan_01H8", "check_holds"}

    # The registrations reached the created position, which is what the
    # page's `initialize:` placement is for: `_ioprocessors` is written
    # once, at the create, and never rewritten by a later stamp.
    assert state.invoke_types == stamps[:invoke_types]
    assert state.send_types == stamps[:send_types]
    assert Map.has_key?(state.datamodel["_ioprocessors"], "myapp:remind")

    acc = eval(acc, first_step)
    execution = fetch(acc, :execution)
    state = fetch(acc, :state)

    assert execution.status == :active
    assert config(state) == ["on_loan"]
    assert state.send_types == stamps[:send_types]

    # The restart: only the execution id survives.
    acc = eval(acc, restart)
    rebooted = fetch(acc, :rebooted)
    assert Machine.identity(rebooted) == Machine.identity(fetch(acc, :machine))

    # The page's claim about a changed chart: the guard refuses it, and the
    # stored position does not move (the next block still starts at on_loan).
    {:ok, changed} =
      acc
      |> fetch(:source)
      |> String.replace("returned", "closed")
      |> Statifier.compile()

    assert {:error, {:identity_mismatch, _stored, _supplied}} =
             Executions.step(
               fetch(acc, :store),
               "loan_01H8",
               changed,
               Event.external("loan.due"),
               fetch(acc, :opts)
             )

    acc = eval(acc, due_step)
    execution = fetch(acc, :execution)
    state = fetch(acc, :state)

    assert execution.status == :active
    assert config(state) == ["due"]

    acc = eval(acc, returned_step)
    execution = fetch(acc, :execution)
    state = fetch(acc, :state)

    assert execution.status == :completed
    assert config(state) == []

    # The page's own "read the configuration back" snippet answers the same.
    {configuration, _acc} = eval_value(acc, read_back)
    assert configuration == []

    # The page's claim about a step delivered to a terminal execution.
    assert {:discarded, %{status: :completed}} =
             Executions.step(
               fetch(acc, :store),
               "loan_01H8",
               rebooted,
               Event.external("loan.due"),
               fetch(acc, :opts)
             )
  end

  defp elixir_blocks(page) do
    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(page, capture: :all_but_first)
    |> List.flatten()
  end

  defp eval(acc, code) do
    {_value, acc} = eval_value(acc, code)
    acc
  end

  defp eval_value({binding, env}, code) do
    quoted = Code.string_to_quoted!(code, file: @page)
    {value, binding, env} = Code.eval_quoted_with_env(quoted, binding, env)
    {value, {binding, env}}
  end

  defp fetch({binding, _env}, name), do: Keyword.fetch!(binding, name)

  defp config(state) do
    state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(state.machine, &1))
    |> Enum.sort()
  end
end
