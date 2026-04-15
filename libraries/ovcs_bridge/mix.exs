defmodule OvcsBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_bridge,
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
      {:ovcs_vehicle, path: "../ovcs_vehicle"},
      {:ovcs_bus, path: "../ovcs_bus"}
    ]
  end
end
