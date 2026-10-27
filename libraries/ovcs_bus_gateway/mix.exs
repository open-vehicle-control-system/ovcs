defmodule OvcsBusGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_bus_gateway,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ovcs_bridge, path: "../ovcs_bridge"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:bandit, "~> 1.14", optional: true},
      {:websock_adapter, "~> 0.5", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:tortoise311, "~> 0.12", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
