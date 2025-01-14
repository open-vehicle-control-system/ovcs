defmodule ObjectDetection.MixProject do
  use Mix.Project

  def project do
    [
      app: :object_detection,
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
      {:yolo, ">= 0.0.0"},
      {:yolo_fast_nms, ">= 0.0.0"},
      {:nx, github: "elixir-nx/nx", sparse: "nx", override: true, branch: "main"},
      {:exla, github: "elixir-nx/exla", sparse: "exla", override: true, branch: "main"},
      {:image, "~> 0.54"},
      {:evision, "~> 0.2.0",
        override: true,
        system_env: [
          "EVISION_PREFER_PRECOMPILED": "false",
          "CMAKE_OPENCV_OPTIONS": "-D WITH VTK=OFF"
        ]},
    ]
  end
end
