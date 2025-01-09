defmodule ROSBridgeFirmware.MixProject do
  use Mix.Project

  @app :ros_bridge_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_rosbridge_system_rpi4
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {ROSBridgeFirmware.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:cantastic, path: "../../../libraries/cantastic"},
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:evision, "~> 0.2"},
      # {:rclex, "~> 0.11.2"},
      {:rclex, github: "open-vehicle-control-system/rclex"},
      {:observer_cli, "~> 1.7"},
      {
        :ovcs_rosbridge_system_rpi4,
        github: "open-vehicle-control-system/ovcs_rosbridge_system_rpi4",
        runtime: false,
        targets: :ovcs_rosbridge_system_rpi4
      },
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
