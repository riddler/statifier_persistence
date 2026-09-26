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

  # V06 is the rename itself (ADR-0011 decision 3): it is the one module
  # whose whole job is to name both spellings, the one it finds on a
  # pre-0.12.0 database and the one it leaves behind. Exempting the file
  # rather than its lines is deliberate - every `run_id` in it is one half
  # of a rename statement, and a line-level list would have to be rewritten
  # whenever that SQL is reworded, for no additional pin.
  @renaming_migration ["lib/statifier_persistence/ecto/migrations/v06.ex"]

  # Line-level survivors. Each is the literal text that makes the line legal.
  @survivor_lines [
    # ADR-0011 decision 4: the pre-0.12.0 donedata key, read for one release
    # and dropped in 0.13.0. A string literal, never an atom.
    {"lib/statifier_persistence/executions.ex", "statifier_persistence:run_status"},
    # The migration helper's own recipe for V06 has to name what V06
    # renames, or a host reading it cannot tell which of its databases the
    # version is for (ADR-0011 decision 3).
    {"lib/statifier_persistence/ecto/migrations.ex", "renames the `runs` table to"},
    {"lib/statifier_persistence/ecto/migrations.ex", "`executions`, both `run_id` columns"}
  ]

  # ADR-0011 decision 1 keeps `run` as an ordinary English verb, and names the
  # one function that carries it: `Executor.run/3` is `@doc false`,
  # package-internal, and is the verb rather than the noun.
  @survivor_names ["run"]

  # Atom survivors, each a whole atom that spells `run` in another sense.
  # ADR-0017 decision 6 names `migrate_batch/3`'s `dry_run:` option and its
  # report's `dry_run` key: a dry run is a rehearsal of the batch, not the
  # retired noun for the durable record. The atom is removed from a line
  # before the line is matched, so any other spelling beside it still
  # fails.
  @survivor_atoms ["dry_run"]

  defp lines(path), do: path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

  defp survivor_line?(path, line) do
    Enum.any?(@survivor_lines, fn {p, text} -> p == path and String.contains?(line, text) end)
  end

  # Two spellings of the same atom: `:runs` anywhere, and `runs:` in
  # keyword syntax, which carries no leading colon and which the first
  # pattern alone cannot see (sp-op4's pass-1 follow-on (a)).
  defp atom_spelling?(line) do
    line =
      Regex.replace(
        ~r/(?<![a-z0-9_])(?:#{Enum.join(@survivor_atoms, "|")})(?![a-z0-9_])/,
        line,
        ""
      )

    Regex.match?(~r/:(?:runs?|run_[a-z0-9_]+|[a-z0-9_]+_runs?)(?![a-z0-9_])/, line) or
      Regex.match?(~r/(?:^\s*|[\[{,]\s*)(?:runs?|run_[a-z0-9_]+|[a-z0-9_]+_runs?):(?!:)/, line)
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
            path not in @renaming_migration,
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
            path not in @renaming_migration,
            {line, number} <- lines(path),
            not survivor_line?(path, line),
            atom_spelling?(line),
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

    # The matcher above is what the two atom spellings are pinned by, and it
    # cannot be sabotaged through lib/ the way the other arms can: a real
    # `runs:` key in lib/ stops the compiler before ExUnit starts (verified -
    # putting the retired key back in `KeyGenerator.UXID`'s `@prefixes`
    # raises `KeyError` while compiling the test support hosts). So the
    # matcher is exercised directly instead, which is also what makes the
    # keyword arm's own scope visible: keyword syntax carries no leading
    # colon, and the English verb followed by a colon is not a key.
    test "the atom matcher sees both spellings and leaves the verb alone" do
      assert atom_spelling?("      {Execution, :runs},")
      assert atom_spelling?("      runs: [")
      assert atom_spelling?(~s(@prefixes %{charts: "chart", runs: "exec"}))
      assert atom_spelling?("  @table_keys [:charts, :runs, :inputs]")

      refute atom_spelling?("    here a non-Postgres adapter cannot run: a table and an index")
      refute atom_spelling?("  # not that nothing has run: the handle is still there")
      refute atom_spelling?("      executions: [")

      # The one atom survivor, and only it: a `dry_run` key or atom passes,
      # and a retired spelling on the same line still fails.
      #
      # sabotage: emptied @survivor_atoms -> red here, and in the atom test
      # above on every `dry_run` line of executions.ex. Verified red,
      # reverted from a copy.
      refute atom_spelling?("    dry_run = Keyword.get(opts, :dry_run, false)")
      refute atom_spelling?("      dry_run: dry_run,")
      assert atom_spelling?("      dry_run: dry_run, run_id: id")
      assert atom_spelling?("    Keyword.get(opts, :dry_runs, false)")
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
            path not in @renaming_migration,
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
