defmodule VisionCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :vision_core,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # The module cache builder is a Mix task.
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # The Port binaries are cross-built for the vision targets only.
  defp compilers do
    base = Mix.compilers()
    if Mix.target() in [:host, :rpi5, :okdo_c100], do: [:elixir_make] ++ base, else: base
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {VisionCore.Application, []}
    ]
  end

  defp deps do
    [
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:ros2_zenoh, path: "../../libraries/ros2_zenoh"},
      {:hailort, path: "../../libraries/hailort", targets: [:host, :rpi5]},
      {:zenohex, "~> 0.8.0"},
      # nx_stereo and nx_iree need Nx 1.0; evision, which works with it, still asks for < 1.0.
      {:nx, "~> 1.0", override: true},
      # Stereo matching on a Vulkan GPU through nx_iree; without a compiler
      # configured it runs on Nx's evaluator. nx_stereo needs nx_iree to compile.
      {:nx_stereo, github: "Spin42/nx_stereo"},
      {:nx_iree, github: "Spin42/nx_iree", override: true},
      {:yaml_elixir, "~> 2.12"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      # OpenCV, the reference the Nx stages are tested against.
      {:evision, "~> 0.2", only: :test},
      # Runs nx_stereo in tests, and compiles its modules for the device on a host.
      {:exla, "~> 1.0", only: [:dev, :test]},
      {:elixir_make, "~> 0.7", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
