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
    common_deps() ++ system_deps(Mix.target())
  end

  # Nerves systems live in separate per-target forks that pin different
  # nerves_system_br versions (rpi3a/rpi4 → 1.29.3, rpi5 → 1.33.7). Mix's
  # constraint resolver evaluates the *full* dep graph regardless of the
  # `:targets` keyword, so listing all three at once produces a "br 1.29.3
  # vs br 1.33.7" conflict at `mix deps.get`. Returning only the active
  # target's system from `deps/0` keeps each MIX_TARGET's resolution
  # independent — they get their own mix.lock entries with no cross-talk.
  defp system_deps(:host), do: []

  defp system_deps(:ovcs_base_can_system_rpi3a) do
    [
      {:ovcs_base_can_system_rpi3a,
       github: "open-vehicle-control-system/ovcs_base_can_system_rpi3a",
       runtime: false,
       nerves: [compile: false]}
    ]
  end

  defp system_deps(:ovcs_base_can_system_rpi4) do
    [
      {:ovcs_base_can_system_rpi4,
       github: "open-vehicle-control-system/ovcs_base_can_system_rpi4",
       runtime: false,
       nerves: [compile: false]}
    ]
  end

  defp system_deps(:rpi5) do
    [
      # OVCS Pi 5 system rebased on upstream nerves_system_rpi5 v2.0.3 with
      # CAN tooling + IPROUTE/IPTABLES + Intel Wi-Fi 6 firmware added.
      # Ships libcamera with PISP pipeline support (the original purpose of
      # this perception bridge — Camera Module 3 stereo on the Pi 5 PiSP FE).
      {:ovcs_bridges_system_rpi5,
       github: "open-vehicle-control-system/ovcs_bridges_system_rpi5",
       tag: "v2.0.8",
       runtime: false,
       nerves: [compile: false]}
    ]
  end

  defp system_deps(other) do
    raise "Unknown MIX_TARGET=#{other}. Add a system_deps/1 clause for it."
  end

  defp common_deps do
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
