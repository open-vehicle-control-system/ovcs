defmodule BridgeFirmware.MixProject do
  use Mix.Project

  @app :bridge_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_base_can_system_rpi3a,
    :ovcs_base_can_system_rpi4,
    :rpi5
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

      # Bridge libraries — enumerated explicitly here (vehicles load
      # at runtime via Code.prepend_path, not as a Mix dep, so they
      # can't pull bridge libs in transitively). Each lib is gated to
      # the Nerves targets it supports. Extend the target lists as
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
       targets: [:host, :ovcs_base_can_system_rpi4, :rpi5],
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
      # Perception bridge target — the OVCS Pi 5 system fork pins
      # `nerves_system_br: 1.29.3` (matching `ovcs_base_can_system_{rpi3a,rpi4}`)
      # so there's no version-conflict on the shared toolchain. It ships
      # the upstream `nerves_system_rpi5` buildroot with libcamera + rpicam
      # apps enabled (`BR2_PACKAGE_RPI_LIBCAMERA_V4L2=y`); HailoRT is not
      # in the defconfig and would need adding for neural inference.
      {
        :ovcs_bridges_system_rpi5,
        github: "open-vehicle-control-system/ovcs_bridges_system_rpi5",
        runtime: false,
        targets: :rpi5,
        nerves: [compile: false]
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
      steps: [&Nerves.Release.init/1, :assemble, &copy_vehicle_app/1],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # See vms/firmware/mix.exs:copy_vehicle_app/1 for the full rationale —
  # the vehicle (`vehicles/<dir>/`) is its own Mix project and not a dep
  # here, so its full OTP app dir (ebin + priv + .app) is hand-copied
  # into the release.
  defp copy_vehicle_app(release) do
    if vehicle_name = System.get_env("VEHICLE") do
      dir = Macro.underscore(vehicle_name)
      src = Path.expand("../../vehicles/#{dir}/_build/dev/lib/#{dir}", __DIR__)

      unless File.dir?(src) do
        Mix.raise("""
        Vehicle app dir not found at:

            #{src}

        Compile the vehicle first (the `./ovcs build` helper does this
        for you):

            (cd vehicles/#{dir} && MIX_TARGET=host mix compile)
        """)
      end

      vsn = read_app_vsn!(src, dir)
      dst = Path.join([release.path, "lib", "#{dir}-#{vsn}"])

      File.rm_rf!(dst)
      File.mkdir_p!(dst)

      # ebin/ and priv/ only — NOT consolidated/. See vms/firmware/mix.exs
      # for why. `cp -rL` dereferences the priv/ symlink in `_build`.
      for sub <- ["ebin", "priv"] do
        sub_src = Path.join(src, sub)
        if File.exists?(sub_src) do
          {_, 0} = System.cmd("cp", ["-rL", sub_src, Path.join(dst, sub)])
        end
      end

      Mix.shell().info("Bundled vehicle #{vehicle_name} app from #{src} → #{dst}")
    end

    release
  end

  defp read_app_vsn!(src_dir, dir) do
    app_file = Path.join([src_dir, "ebin", "#{dir}.app"])

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, _name, props}]} ->
        case Keyword.fetch(props, :vsn) do
          {:ok, vsn} -> List.to_string(vsn)
          :error -> Mix.raise("No :vsn in #{app_file}")
        end

      other ->
        Mix.raise("Could not read #{app_file}: #{inspect(other)}")
    end
  end
end
