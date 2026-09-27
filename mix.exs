defmodule RfxtrxMqtt.MixProject do
  use Mix.Project

  def project do
    [
      app: :rfxtrx_mqtt,
      version: "0.2.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: [rfxtrx_mqtt: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RfxtrxMqtt.Application, []}
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
