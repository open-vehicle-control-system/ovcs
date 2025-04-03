defmodule VmsFirmware.MixProject do
  use Mix.Project

  @app :vms_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_base_can_system_rpi4
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.11",
      archives: [nerves_bootstrap: "~> 1.12"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host]
    ]
  end

  def application do
    [
      mod: {VmsFirmware.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.10.0"},
      {:toolshed, "~> 0.3.0"},
      {:observer_cli, "~> 1.7"},
      {:nerves_runtime, "~> 0.13.0"},
      {:nerves_pack, "~> 0.7.0", targets: @all_targets},
      {:vms_api, path: "../api", targets: @all_targets, env: Mix.env()},
      {
        :ovcs_base_can_system_rpi4,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi4",
        runtime: false,
        targets: :ovcs_base_can_system_rpi4,
        nerves: [compile: false],
      }
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
