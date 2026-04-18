defmodule OvcsCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_cli,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: OvcsCli, name: "ovcs"],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :eex, :mix]]
  end

  defp deps do
    [
      {:optimus, "~> 0.5"},
      {:ovcs_vehicle, path: "../libraries/ovcs_vehicle"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
