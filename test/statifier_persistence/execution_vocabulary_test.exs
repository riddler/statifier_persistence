defmodule StatifierPersistence.ExecutionVocabularyTest do
  use ExUnit.Case, async: true

  # ADR-0011 decision 2 is a rule, not a table: `run` is retired as the noun
  # naming the durable record, across every public surface of this package.
  # The changelog fragment for 0.12.0 is the authoritative enumeration of what
  # was renamed, and this test is what makes that enumeration true - it fails
  # on any surface the rule already renamed that was missed.
  #
  # Every permitted survivor is named here, with the reason it survives.

  @lib_files Path.wildcard("lib/**/*.ex")

  # ADR-0011 decision 3 - the `:runs` table key, the `run_id` columns, the
  # index names and the historical migrations - is sp-j2y's half of the
  # rename and lands in the same release (0.12.0) in its own PR. Until it
  # does, these files still spell the retired noun at the SQL layer only.
  # sp-j2y deletes this list.
  @deferred_to_sp_j2y [
                        "lib/statifier_persistence/ecto/config.ex",
                        "lib/statifier_persistence/ecto/migrations.ex"
                      ] ++ Path.wildcard("lib/statifier_persistence/ecto/migrations/*.ex")

  # Line-level survivors. Each is the literal text that makes the line legal.
  @survivor_lines [
    # ADR-0011 decision 4: the pre-0.12.0 donedata key, read for one release
    # and dropped in 0.13.0. A string literal, never an atom.
    {"lib/statifier_persistence/executions.ex", "statifier_persistence:run_status"},
    # sp-j2y again, at line level: the adapter opt naming the table and the
    # two index names V01 and V05 created.
    {"lib/statifier_persistence/storage/ecto.ex", ":runs_table"},
    {"lib/statifier_persistence/storage/ecto.ex", "Config.table(config, :runs)"},
    {"lib/statifier_persistence/storage/ecto.ex", "_run_id_index"},
    {"lib/statifier_persistence/storage/ecto.ex", "_run_id_seq_index"},
    {"lib/statifier_persistence/storage/ecto.ex", "V06 (sp-j2y)"},
    # sp-j2y at line level in the three files that carry only a handful of
    # decision-3 lines, so that decision 2's own surfaces in them - the
    # generated `Execution` module name and its `execution_id` field - stay
    # pinned by the arms above.
    {"lib/statifier_persistence/ecto.ex", "`statifier_runs`"},
    {"lib/statifier_persistence/ecto.ex", "{Execution, :runs}"},
    {"lib/statifier_persistence/ecto.ex", "runs: ["},
    {"lib/statifier_persistence/ecto.ex", "source: :run_id"},
    {"lib/statifier_persistence/ecto/key_generator.ex", "@type table ::"},
    {"lib/statifier_persistence/ecto/key_generator/uxid.ex", "@prefixes %{"}
  ]

  # ADR-0011 decision 1 keeps `run` as an ordinary English verb, and names the
  # one function that carries it: `Executor.run/3` is `@doc false`,
  # package-internal, and is the verb rather than the noun.
  @survivor_names ["run"]

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

  defp survivor_line?(path, line) do
    Enum.any?(@survivor_lines, fn {p, text} -> p == path and String.contains?(line, text) end)
  end

  defp retired_noun?(name) do
    snake = name |> String.split("_") |> Enum.any?(&(&1 in ["run", "runs"]))
    camel = Regex.match?(~r/Runs?(?![a-z])/, name)
    snake or camel
  end

  describe "the retired noun (ADR-0011 decisions 1 and 2)" do
    # sabotage: renamed Executions.step/5 back to step_run/5 -> red here,
    # naming the definition. Verified red, reverted.
    test "no module, function, type, spec or callback in lib/ is named for it" do
      offenders =
        for path <- @lib_files,
            path not in @deferred_to_sp_j2y,
            {line, number} <- lines(path),
            name <- declared_names(line),
            name not in @survivor_names,
            retired_noun?(name),
            not survivor_line?(path, line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == []
    end

    # sabotage: changed one `refuse_unidentified/2` call in storage.ex back
    # to the `:run` stage -> red, naming that line. A second mutation, added
    # when the pass-1 review found the first alternation too narrow: one
    # member of `Adapter.error/0` back to `:run_not_found` -> red, naming
    # `adapter.ex:203`. Both verified red, reverted from a copy.
    test "no atom literal in lib/ spells it" do
      offenders =
        for path <- @lib_files,
            path not in @deferred_to_sp_j2y,
            {line, number} <- lines(path),
            not survivor_line?(path, line),
            Regex.match?(~r/:(?:runs?|run_[a-z0-9_]+|[a-z0-9_]+_runs?)(?![a-z0-9_])/, line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == []
    end

    # ADR-0011 decision 5: this package emits the new prefix and nothing else.
    #
    # sabotage: put `:run` back as the second segment of
    # `@execution_step_start` -> red. Verified red, reverted.
    test "no telemetry event name in lib/ spells it" do
      offenders =
        for path <- @lib_files,
            {line, number} <- lines(path),
            String.contains?(line, ":statifier_persistence, :run"),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == []
    end

    # The broadest arm: the `run_id` / `run_status` spellings anywhere in
    # lib/, which is what catches a key inside a type's own shape, an error
    # atom in a union, and a doc that still tells a host the old name.
    #
    # sabotage: renamed Executor.context/0's :execution_id key back to
    # :run_id -> red, naming executor.ex. A second mutation, added when the
    # pass-1 review found the leading word boundary could not match inside a
    # longer key: one `parent_execution_id` in telemetry.ex back to
    # `parent_run_id` -> red, naming that line. Both verified red, reverted
    # from a copy.
    test "no `run_id` or `run_status` spelling survives in lib/" do
      offenders =
        for path <- @lib_files,
            path not in @deferred_to_sp_j2y,
            {line, number} <- lines(path),
            not survivor_line?(path, line),
            Regex.match?(~r/run_(?:id|status)(?![a-z0-9_])/, line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == []
    end
  end

  # The names a line declares: module, function and macro definitions, and
  # the name a @type / @spec / @callback heads.
  defp declared_names(line) do
    definition =
      case Regex.run(~r/^\s*(?:def|defp|defmacro|defmacrop)\s+([a-z_][A-Za-z0-9_]*[?!]?)/, line) do
        [_all, name] -> [name]
        nil -> []
      end

    module =
      case Regex.run(~r/^\s*defmodule\s+([A-Za-z0-9_.]+)/, line) do
        [_all, name] -> String.split(name, ".")
        nil -> []
      end

    typed =
      case Regex.run(
             ~r/^\s*@(?:spec|type|typep|opaque|callback|macrocallback)\s+([a-z_][A-Za-z0-9_]*[?!]?)/,
             line
           ) do
        [_all, name] -> [name]
        nil -> []
      end

    definition ++ module ++ typed
  end
end
