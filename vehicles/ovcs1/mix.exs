defmodule Ovcs1.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs1,
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
      {:vms_core, path: "../../vms/core"},
      {:infotainment_core, path: "../../infotainment/core"}
    ]
  end
end
