defmodule InfotainmentCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :infotainment_core,
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
      mod: {InfotainmentCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:json, "~> 1.4"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"}
    ]
  end
end
