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
      {:json, "~> 1.4"}
    ]
  end
end
