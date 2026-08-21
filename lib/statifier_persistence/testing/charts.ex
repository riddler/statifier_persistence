defmodule StatifierPersistence.Testing.Charts do
  @moduledoc """
  Tiny compiled charts for this package's own tests and for the conformance
  template (ADR-0003 decision 5).

  Two SCXML sources, `chart_a/0` and `chart_b/0`, differ by exactly one
  state so `Statifier.Machine.Identity.of_source/2`'s content hash differs
  between them - the guard test needs a real recompiled revision, not a
  hand-forged identity struct, or it does not exercise what the guard
  exists to catch.

  This module lives in `lib/`, not the test-only `support/` directory, because Phase 4's
  conformance template also lives in `lib/` (under this same
  `StatifierPersistence.Testing.*` namespace) and may not reference
  anything under `test/` (ADR-0003 decision 5, st-ADR-0053's rule).
  """

  alias Statifier.Machine

  @chart_a_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @chart_b_source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <transition event="go" target="c"/>
      </state>
      <state id="c"/>
  </scxml>
  """

  @doc """
  Compiles and returns chart "a" as `{source, machine}`.
  """
  @spec chart_a() :: {binary(), Machine.t()}
  def chart_a, do: compile!(@chart_a_source)

  @doc """
  Compiles and returns chart "b" as `{source, machine}`. Differs from
  `chart_a/0` by one extra state, so its content hash differs.
  """
  @spec chart_b() :: {binary(), Machine.t()}
  def chart_b, do: compile!(@chart_b_source)

  @doc """
  Returns a compiled `Machine.t()` with its `identity` stripped.

  `Statifier.Compiler.compile/1` takes a `Statifier.Document.t()`, not
  source bytes (`deps/statifier/lib/statifier/compiler.ex:208`), so the
  cheap way to build an unidentified machine in a test is this struct
  update on an already-compiled one, rather than driving the compiler
  pipeline by hand.
  """
  @spec unidentified_machine() :: Machine.t()
  def unidentified_machine do
    {_source, machine} = chart_a()
    %{machine | identity: nil}
  end

  @spec compile!(binary()) :: {binary(), Machine.t()}
  defp compile!(source) do
    case Statifier.compile(source) do
      {:ok, machine} ->
        {source, machine}

      {:error, errors} ->
        raise "StatifierPersistence.Testing.Charts fixture failed to compile: #{inspect(errors)}"
    end
  end
end
