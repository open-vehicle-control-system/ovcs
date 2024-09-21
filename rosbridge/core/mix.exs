defmodule OvcsRosBridgeCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_ros_bridge_core,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {OvcsRosBridgeCore.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rclex, github: "rclex/rclex", tag: "v0.11.0"},
    ]
  end
end
