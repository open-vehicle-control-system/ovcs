defmodule VisionApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :vision_api,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  def application do
    [
      mod: {VisionApi.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.11"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.2"},
      {:cors_plug, "~> 3.0.3"},
      {:vision_core, path: "../core"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
