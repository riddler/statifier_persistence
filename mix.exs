defmodule StatifierPersistence.MixProject do
  use Mix.Project

  @version "0.1.0"
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

  defp deps do
    [
      statifier_dep(),

      # Dev / test
      {:ex_quality, "~> 0.13", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Statifier is not on Hex - it has no package/0 and no tags - so the default
  # is a git dep whose SHA mix.lock pins. Note the consequence: Hex refuses to
  # publish a package that carries a git dependency, so this package cannot
  # ship until statifier is published. That is upstream's call, not ours.
  #
  # Ecto is deliberately absent: the storage-adapter behaviour, run lifecycle,
  # and stepper loop need none of it. The Ecto adapter epic decides its own
  # dependency shape (ecto_sql optional vs a separate statifier_ecto package)
  # when that work starts.
  #
  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil -> {:statifier, github: "riddler/statifier-ex", branch: "main"}
      path -> {:statifier, path: path, override: true}
    end
  end
end
