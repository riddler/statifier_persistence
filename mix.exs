defmodule StatifierPersistence.MixProject do
  use Mix.Project

  @version "0.3.0"
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches.
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
        "docs/restart-demo.md"
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
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      statifier_dep(),
      {:uxid, "~> 2.0"},
      {:ecto_sql, "~> 3.10", optional: true},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:postgrex, "~> 0.19", only: :test}
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
  # The floor is 2.2.1: the first release carrying the queue-discard-on-exit
  # fix this package's completion conformance cases need (a session that
  # reaches a top-level <final> leaves an empty internal queue, so a :done
  # MachineState is quiescent by construction and reaches the persist tail).
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil ->
        {:statifier, "~> 2.2 and >= 2.2.1"}

      path ->
        {:statifier, path: path, override: true}
    end
  end
end
