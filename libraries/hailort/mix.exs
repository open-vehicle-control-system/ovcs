defmodule Hailort.MixProject do
  use Mix.Project

  def project do
    [
      app: :hailort,
      version: "4.24.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps()
    ]
  end

  # libhailort is built only when cross-compiling for a Nerves target.
  defp compilers do
    base = Mix.compilers()
    if Mix.target() == :host, do: base, else: [:elixir_make] ++ base
  end

  def application do
    []
  end

  defp deps do
    [
      {:elixir_make, "~> 0.7", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
