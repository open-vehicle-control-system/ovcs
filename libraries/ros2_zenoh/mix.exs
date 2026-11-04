defmodule Ros2Zenoh.MixProject do
  use Mix.Project

  def project do
    [
      app: :ros2_zenoh,
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
      # `Ros2Zenoh.Client`'s session.
      {:zenohex, "~> 0.8.0"},
      # The golden CDR fixtures in test/support.
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
