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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {VmsCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:jason, "~> 1.2"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:ovcs_control, path: "../../libraries/ovcs_control"},
      # For `OvcsVehicle.geometry/0`'s type and the kinematic helpers
      # that operate on it. A contract library with one dependency of
      # its own, so no cycle: `vms_core` was already coupled to the
      # vehicle concept via `Application.get_env(:vms_core, :vehicle)`,
      # it just had no way to read the geometry that comes with it.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:crc, "~> 0.10"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:decimal, "~> 2.1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
