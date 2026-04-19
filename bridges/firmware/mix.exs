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
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},
      # Bridge CAN YAMLs often `import!:@ovcs_can:...` shared frame
      # definitions, so the app must be loaded in every bridge BEAM.
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      # `OvcsVehicle.Firmware.resolve_vehicle/3` is used from
      # `config/runtime.exs` to prepend the vehicle's ebin.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},

      # Align cowlib across emqtt (~> 2.7) and the Nerves stack
      # (~> 2.13). Widened from 2.7 so the host-dev BEAM can bundle
      # ros_bridge alongside Phoenix (which needs ~> 2.16).
      {:cowlib, "~> 2.13", override: true},

      # Bridge libraries — enumerated explicitly here (vehicles load
      # at runtime via Code.prepend_path, not as a Mix dep, so they
      # can't pull bridge libs in transitively). Each lib is gated to
      # the Nerves targets it supports so a rpi3a build doesn't drag
      # ros_bridge's emqtt/quicer chain in. Extend the target lists as
      # bridges gain new SoC support, or add a new bridge by listing
      # it here + target gates.
      #
      # On host dev every bridge matches (targets include `:host`), so
      # both ros + radio_control would sit in bridge_firmware's dep
      # tree at once and OTP would auto-start each one's Application —
      # including the inactive bridge's supervision stack (e.g. the
      # Mavlink Parser shows up inside the ros BEAM and spams logs).
      # Mark them `runtime: false` on host to let `OvcsBridge.Supervisor`
      # be the sole authority on which bridge actually boots; on target
      # only the matching bridge is in the dep tree anyway, so OTP
      # auto-start stays the way it was.
      {:radio_control_bridge,
       path: "../radio_control_bridge",
       targets: [:host, :ovcs_base_can_system_rpi3a],
       runtime: Mix.target() != :host},
      {:ros_bridge,
       path: "../ros_bridge",
       targets: [:host, :ovcs_base_can_system_rpi4, :ovcs_bridges_system_rpi5],
       runtime: Mix.target() != :host},

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
      },
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}

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
