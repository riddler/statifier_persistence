defmodule StatifierPersistence.ShippedProseTest do
  use ExUnit.Case, async: true

  # A decision this package ships is cited by the public record that carries
  # it - an ADR in docs/adr/, by number and section - and its substance is
  # written out in words. The tracker a decision was taken in, its private
  # ruling and question numbers, and the planning campaign that took it are
  # not public, so an id of any of those shapes in a file the Hex package
  # ships points a reader at nothing they can open.
  #
  # The files scanned are the package's own `files:` list in mix.exs, read at
  # test time, so a file added to the package is scanned without a change
  # here. docs/adr/ and test/ are not shipped and are not scanned.

  # Private ruling and question ids. The shapes are those statifier_blocks'
  # guard (test/statifier_blocks/block_type_test.exs) matches: a question
  # record id, a numbered ruling with a sub-number or a letter, a lettered
  # ruling, a numbered decision pair, and a bare `R`/`Q` number when a
  # ruling or question word sits beside it.
  @private_ruling_id ~r/
    \bRQ-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*
    | \bR\d+(?:[-.]\d+|[a-z])\b
    | \bR-[a-z]\b
    | \bD\d+-\d+\b
    | \b(?:[Rr]ulings?|[Ee]pic|[Qq]uestions?)\s+[`*]*\K[RQ]\d+(?:[-.]\d+|[a-z])?\b
    | \b[RQ]\d+(?:[-.]\d+|[a-z])?(?=[`*]*,?\s+(?:operator\s+)?ruling\b)
  /x

  # Campaign ids, which the statifier_blocks pattern does not cover: a
  # two-letter campaign prefix and a number, in either case (the lower-case
  # spelling is how a campaign names its labels), and a bare campaign
  # number after the word.
  @campaign_id ~r/
    \b(?i:RF|SF)\d{3}[a-z]?\b
    | \b[Cc]ampaign[\s-]+\d{3}[a-z]?\b
  /x

  defp private_ids(text) do
    for pattern <- [@private_ruling_id, @campaign_id],
        [id | _] <- Regex.scan(pattern, text),
        do: id
  end

  defp shipped_files do
    Mix.Project.config()
    |> Keyword.fetch!(:package)
    |> Keyword.fetch!(:files)
    |> Enum.flat_map(fn entry ->
      if File.dir?(entry),
        do: entry |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1),
        else: [entry]
    end)
    |> Enum.sort()
  end

  # sabotage: drop the `(?i:` group from @campaign_id -> red on the
  # lower-case campaign positive (verified, restored from a copy).
  test "the pattern matches each private id shape and no ordinary text" do
    # Invented ids in each shape; none of them names a real entry.
    positives = [
      {"see RQ-XX999-99 for why", "RQ-XX999-99"},
      {"see RQ-999-9b for why", "RQ-999-9b"},
      {"under ruling R99-9, the", "R99-9"},
      {"under ruling R99.9, the", "R99.9"},
      {"as R99z has it", "R99z"},
      {"the ruling R-z said", "R-z"},
      {"the ruling `D99-9` said", "D99-9"},
      {"under operator ruling R98, the", "R98"},
      {"behind epic `R97`", "R97"},
      {"open question Q99 asks", "Q99"},
      {"the R96 ruling of", "R96"},
      {"(R95, operator ruling 2026-01-01)", "R95"},
      {"taken in RF999 at its walk", "RF999"},
      {"from SF999's synthesis", "SF999"},
      {"labelled rf999-candidate", "rf999"},
      {"since campaign 999, the", "campaign 999"},
      {"as Campaign-999 found", "Campaign-999"}
    ]

    for {text, id} <- positives, do: assert(private_ids(text) == [id], text)

    negatives = [
      "Rule 3 of the walk",
      "released as v0.12.0",
      "ADR-0011 decision 3",
      "the V01-V05 migrations",
      "RFC 7231 section 6",
      "a question the compiler asks",
      "the ruling of 2026-08-29",
      "the campaign that took it",
      "`execution_id` is a UXID"
    ]

    for text <- negatives, do: assert(private_ids(text) == [], text)
  end

  test "the scan covers every file the package ships" do
    files = shipped_files()

    assert "mix.exs" in files
    assert "lib/statifier_persistence/ecto/migrations.ex" in files
    assert Enum.all?(files, &File.regular?/1)
  end

  # sabotage: plant an invented id of a private ruling shape in a copy of
  # ecto/migrations.ex's moduledoc -> red, naming the file, line and id;
  # restore the copy -> green (both verified).
  test "no file the package ships carries a private ruling or campaign id" do
    offenders =
      for file <- shipped_files(),
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          id <- private_ids(line),
          do: "#{file}:#{number}: #{id}"

    assert offenders == [],
           "private ruling or campaign ids in shipped files - cite the public " <>
             "record and write the decision's substance instead:\n" <>
             Enum.join(offenders, "\n")
  end
end
