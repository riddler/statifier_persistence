defmodule StatifierPersistence.MixProject do
  use Mix.Project

  @version "0.20.0"
  @source_url "https://github.com/riddler/statifier_persistence"

  def project do
    [
      app: :statifier_persistence,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "StatifierPersistence",
      description: "Durable stepper and storage adapters for Statifier",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # `test/dialyzer/` holds callers written the way a host writes them, for
  # the Dialyzer stage to read: `mix dialyzer` runs in `:dev`, so it is
  # compiled there as well as in `:test`. Never in `:prod`, and never in the
  # package's `files:`. `test/statifier_persistence/dialyzer_fixture_paths_test.exs`
  # fails when `test/dialyzer` drops out of the `:dev` list.
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/dialyzer"]
  defp elixirc_paths(:dev), do: ["lib", "test/dialyzer"]
  defp elixirc_paths(_), do: ["lib"]

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time - the docs tarball hexdocs hosts is built separately from
  # the package tarball `mix deps.get` fetches. A guide the README links to
  # relatively is ALSO listed in package()'s files: list, because hex.pm
  # renders the README from the package tarball and resolves that link
  # inside it; one relative link then works on GitHub, HexDocs and hex.pm.
  defp docs do
    [
      name: "StatifierPersistence",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier_persistence",
      source_url: @source_url,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/restart-demo.md",
        "docs/non-postgres-backends.md",
        "docs/telemetry.md",
        "docs/retention.md"
      ],
      groups_for_extras: [
        Guides: ~r{docs/}
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      name: "statifier_persistence",
      licenses: ["MIT"],
      files: ~w(
        lib
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        docs/restart-demo.md
        docs/non-postgres-backends.md
        docs/telemetry.md
        docs/retention.md
      ),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      statifier_dep(),
      # Direct, not transitive: this package calls :telemetry.execute/3
      # itself (ADR-0009 decision 1), and a package that does declares it.
      # It is already in every dependent's tree through statifier, so no
      # host's lock file grows.
      {:telemetry, "~> 1.3"},
      {:uxid, "~> 2.0"},
      {:ecto_sql, "~> 3.10", optional: true},

      # Dev / test
      {:ex_quality, "~> 0.15", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:postgrex, "~> 0.19", only: :test},
      # Test-only, and only so the migration helper's non-Postgres path is
      # exercised by a real adapter rather than asserted about (sp-11w).
      # ADR-0005 decision 2's Postgres harness is untouched: every
      # storage and conformance test still runs against Postgres.
      {:ecto_sqlite3, "~> 0.21", only: :test}
    ]
  end

  # The Ecto layer's dependency shape (ecto_sql optional here vs a separate
  # statifier_ecto package, uxid required, postgrex test-only) is decided in
  # ADR-0005 - see docs/adr/0005-ecto-in-package-and-postgres-test-harness.md.
  #
  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  #
  # The floor is 2.9: the first release whose `Statifier.MachineState`
  # carries `last_selection`, which the step stop's `selection` key is read
  # from (the ADR-0009 sp-qrkx amendment). It subsumes the previous 2.6
  # floor, the first release carrying host-registered send types.
  # `Statifier.MachineState.put_send_types/2` is what stamps a `send_types:`
  # snapshot back onto a decoded position, and without it a
  # `<send type="myapp:sink">` on a durable execution classifies as
  # unsupported and raises `error.execution` before any effect exists. That
  # floor in turn subsumed 2.2.1 (the queue-discard-on-exit fix this
  # package's completion conformance cases need: a session that reaches a
  # top-level <final> leaves an empty internal queue, so a :done
  # MachineState is quiescent by construction and reaches the persist tail).
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil ->
        {:statifier, "~> 2.9"}

      path ->
        {:statifier, path: path, override: true}
    end
  end
end
