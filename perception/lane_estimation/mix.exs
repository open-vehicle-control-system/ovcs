defmodule LaneEstimation.MixProject do
  use Mix.Project

  def project do
    [
      app: :lane_estimation,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nx, "~> 0.9.1"},
      {:exla, "~> 0.9.0"},
      {:image, "~> 0.54.4"},
      {:rclex, "~> 0.11.2"},
      {:evision, "~> 0.2.0",
        override: true,
        system_env: [
          "EVISION_PREFER_PRECOMPILED": "false",
          "CMAKE_OPENCV_OPTIONS": "-D WITH VTK=OFF"
        ]},
      {:kino, "~> 0.14.0"},
      {:scholar, "~> 0.3.0"}
    ]
  end
end
