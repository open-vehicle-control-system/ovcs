defmodule VmsCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :vms_core,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {VmsCore.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:ovcs_control, path: "../../libraries/ovcs_control"},
      # The vehicle geometry contract and its kinematic helpers.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:crc, "~> 0.10"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:decimal, "~> 3.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
