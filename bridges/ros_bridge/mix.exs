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
      # Previously pinned to ~> 2.7.0; cowboy (Phoenix side) wants
      # ~> 2.16 so the ros_bridge + Phoenix combination wouldn't
      # coexist in one BEAM. Widening to any 2.x satisfies both
      # emqtt (declared ~> 2.7) and cowboy (declared ~> 2.16).
      {:cowlib, "~> 2.13", override: true},
      {:emqtt, "~> 1.10"},
      {:zenohex, "~> 0.9.0"},
      {:circuits_i2c, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
