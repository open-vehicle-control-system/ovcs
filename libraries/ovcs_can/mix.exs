defmodule OvcsCan.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_can,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Tests load every frame through Cantastic, as a firmware does at boot.
      {:cantastic, path: "../cantastic", only: :test, runtime: false},
      {:yaml_elixir, "~> 2.12", only: :test},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
