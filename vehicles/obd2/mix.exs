defmodule Obd2.MixProject do
  use Mix.Project

  def project do
    [
      app: :obd2,
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
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:vms_core, path: "../../vms/core"},
      {:infotainment_core, path: "../../infotainment/core"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
