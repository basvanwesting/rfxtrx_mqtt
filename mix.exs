defmodule ForestShuttle.MixProject do
  use Mix.Project

  def project do
    [
      app: :forest_shuttle,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: [forest_shuttle: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ForestShuttle.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:circuits_uart, "~> 1.6"},
      {:tortoise311, "~> 0.12"}
    ]
  end
end
