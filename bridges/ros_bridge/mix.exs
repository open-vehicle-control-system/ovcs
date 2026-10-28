defmodule RosBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ros_bridge,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps()
    ]
  end

  # camera_capture links libcamera, present only in the rpi5 sysroot.
  defp compilers do
    base = Mix.compilers()
    if Mix.target() == :rpi5, do: [:elixir_make] ++ base, else: base
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},
      {:ovcs_drivers, path: "../../libraries/ovcs_drivers"},
      {:hailort, path: "../../libraries/hailort", targets: [:host, :rpi5]},
      {:zenohex, "~> 0.8.0"},
      # Joy profiles (`RosBridge.Consumers.Joy.Profile`).
      {:yaml_elixir, "~> 2.12"},
      {:elixir_make, "~> 0.7", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # `RosBridge.StereoCamera.OpenCV`; precompiled on x86_64 hosts, built
      # against the system OpenCV on target.
      {:evision, "~> 0.2"},
      {:nx, "~> 0.7"}
    ]
  end
end
