defmodule RosBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ros_bridge,
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
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},
      {:ovcs_drivers, path: "../../libraries/ovcs_drivers"},
      {:ros2_zenoh, path: "../../libraries/ros2_zenoh"},
      {:zenohex, "~> 0.8.0"},
      # Joy profiles (`RosBridge.Consumers.Joy.Profile`).
      {:yaml_elixir, "~> 2.12"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
