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

  # The camera_capture native C++ binary only builds on :rpi5 — it
  # links libcamera, which only exists on the perception target. On
  # every other target we skip elixir_make entirely so `mix compile`
  # doesn't shell out to make. (Hailo inference is no longer a Port
  # binary; the nx_hailo NIF replaces it — see deps/0.)
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
      {:zenohex, "~> 0.9.0"},
      {:elixir_make, "~> 0.7", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # OpenCV bindings + Nx — used by `Stereo.OpenCV` for JPEG
      # decode, rectification, and StereoSGBM. Evision ships
      # precompiled NIFs for x86_64 Linux (via rustler_precompiled)
      # so it's free to install on host; on target it builds against
      # the system OpenCV.
      {:evision, "~> 0.2"},
      {:nx, "~> 0.7"}
    ]
  end
end
