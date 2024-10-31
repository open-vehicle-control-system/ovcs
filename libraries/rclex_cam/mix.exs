defmodule RclexCam.MixProject do
  use Mix.Project

  def project do
    [
      app: :rclex_cam,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [
        compile: ["rclex.gen.msgs", "compile"]
      ]


      # deps/rclex/scripts/prepare_ros2_resources.exs
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {RclexCam.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:evision, "~> 0.2"},
      {:rclex, github: "open-vehicle-control-system/rclex"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
