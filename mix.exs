defmodule StatifierPersistence.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/riddler/statifier_persistence"

  def project do
    [
      app: :statifier_persistence,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "StatifierPersistence",
      description: "Durable stepper and storage adapters for Statifier",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
