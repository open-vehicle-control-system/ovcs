defmodule BridgeFirmware.MixProject do
  use Mix.Project

  @app :bridge_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_base_can_system_rpi3a,
    :ovcs_base_can_system_rpi4,
    :ovcs_bridges_system_rpi5
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

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {BridgeFirmware.Application, []}
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:observer_cli, "~> 1.8"},
      {:nerves_runtime, "~> 0.13.0"},
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},

      # Bridge libraries — available for vehicles to declare in
      # their bridge_firmwares/0 map. The runtime supervisor only
      # starts children from the bridges actually listed, so bundling
      # an unused bridge here doesn't cost anything.
      {:radio_control_bridge, path: "../radio_control_bridge"},
      {:ros_bridge, path: "../ros_bridge"},

      # Nerves systems (one per supported target).
      {
        :ovcs_base_can_system_rpi3a,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi3a",
        runtime: false,
        targets: :ovcs_base_can_system_rpi3a,
        nerves: [compile: false]
      },
      {
        :ovcs_base_can_system_rpi4,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi4",
        runtime: false,
        targets: :ovcs_base_can_system_rpi4,
        nerves: [compile: false]
      },
      {
        :ovcs_bridges_system_rpi5,
        github: "open-vehicle-control-system/ovcs_bridges_system_rpi5",
        runtime: false,
        targets: :ovcs_bridges_system_rpi5
      }

      # Bridge libraries are added as each is migrated out of its
      # legacy bridges/<name>/firmware/ project. The supervisor only
      # starts children from the bridges declared by the active
      # vehicle's bridge_firmwares/0 entry, so bundling a lib here
      # doesn't force it to run.
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
