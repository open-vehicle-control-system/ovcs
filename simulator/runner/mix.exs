defmodule SimulatorRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :simulator_runner,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SimulatorRunner.Application, []}]
  end

  defp deps do
    [
      {:simulator_core, path: "../core"},
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      # Vehicle topologies import their frames from it (`import!:@ovcs_can:`).
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
