defmodule OvcsVehicle.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_vehicle,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger, :eex, :mix]]
  end
end
