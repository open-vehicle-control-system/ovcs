defmodule VisionFirmware.MixProject do
  use Mix.Project

  @app :vision_firmware
  @version "0.1.0"
  @all_targets [:rpi5, :okdo_c100]

  def project do
    [
      app: @app,
      # Stamped into the image as `meta-product`, which NervesHub keys
      # firmware on: one product per vehicle, `<Vehicle Name> - Vision`.
      name: firmware_product(),
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  def application do
    [
      mod: {VisionFirmware.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Host-side tasks (deps.get, test, compile) may run without VEHICLE.
  defp firmware_product do
    case System.get_env("VEHICLE") do
      nil ->
        to_string(@app)

      vehicle ->
        vehicle_name =
          vehicle
          |> Macro.underscore()
          |> String.split("_")
          |> Enum.map_join(" ", &String.capitalize/1)

        "#{vehicle_name} - Vision"
    end
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
      {:nerves_hub_link, "~> 2.12", targets: @all_targets},
      {:vision_api, path: "../api"},
      # Compiles the Nx stereo stages on a workstation; boards load
      # precompiled modules.
      {:exla, "~> 1.0", targets: :host},
      # `OvcsVehicle.Firmware.resolve_side/4` is used from
      # `config/runtime.exs` to prepend the vehicle's ebin.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      # The OVCS Pi 5 system: libcamera with the PiSP pipeline, which
      # `camera_capture` links, and the Hailo-8 driver `hailo_detect` drives.
      {:ovcs_bridges_system_rpi5,
       github: "open-vehicle-control-system/ovcs_bridges_system_rpi5",
       tag: "v3.0.0-rc.2",
       runtime: false,
       targets: :rpi5,
       nerves: [compile: false]},
      # The OKdo Nano C100 (Jetson Nano): the CSI camera drivers
      # `v4l2_capture` reads, and Mesa NVK for `nx_stereo` on Vulkan.
      {:nerves_system_okdo_c100,
       github: "Spin42/nerves_system_okdo_c100",
       tag: "v0.2.0",
       runtime: false,
       targets: :okdo_c100,
       nerves: [compile: false]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  def release do
    [
      overwrite: true,
      # Shared by every OVCS firmware and by `./ovcs run` / `./ovcs
      # attach`, so the vehicle's BEAMs authenticate each other. Passed
      # to the VM by `-setcookie` in rel/vm.args.eex.
      cookie: "ovcs",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble, &copy_vehicle_app/1],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # See vms/firmware/mix.exs:copy_vehicle_app/1 for the full rationale:
  # the vehicle (`vehicles/<dir>/`) is its own Mix project and not a dep
  # here, so its OTP app dir (ebin + priv + .app) is hand-copied into the
  # release.
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

      # ebin/ and priv/ only, not consolidated/: see vms/firmware/mix.exs.
      # `cp -rL` dereferences the priv/ symlink in `_build`.
      for sub <- ["ebin", "priv"] do
        sub_src = Path.join(src, sub)

        if File.exists?(sub_src) do
          {_, 0} = System.cmd("cp", ["-rL", sub_src, Path.join(dst, sub)])
        end
      end

      Mix.shell().info("Bundled vehicle #{vehicle_name} (ebin + priv) from #{src} → #{dst}")
      check_required_files!(vehicle_name, src, dst)
    end

    release
  end

  # Files the vision composer lists in `required_files/0` (relative to
  # the vehicle app, e.g. a model under priv/) that are not committed. A
  # vision unit missing one boots but cannot do its job, so the build
  # fails instead.
  defp check_required_files!(vehicle_name, src, dst) do
    Code.prepend_path(Path.join(src, "ebin"))
    vehicle = Module.concat([vehicle_name])

    unless Code.ensure_loaded?(vehicle) and function_exported?(vehicle, :vision, 0) do
      Mix.raise("#{vehicle_name} declares no vision unit: it does not implement vision/0.")
    end

    composer = vehicle.vision()

    unless Code.ensure_loaded?(composer) do
      Mix.raise("#{vehicle_name}.vision/0 returns #{inspect(composer)}, which is not compiled.")
    end

    required_files =
      if function_exported?(composer, :required_files, 0),
        do: composer.required_files(),
        else: []

    missing = Enum.reject(required_files, &File.exists?(Path.join(dst, &1)))

    if missing != [] do
      Mix.raise("""
      The vision firmware of #{vehicle_name} requires files that are missing:

      #{Enum.map_join(missing, "\n", &"    #{&1}")}

      They are listed by #{inspect(composer)}.required_files/0. Detection
      models are not committed; fetch them from the repo root with:

          mise run fetch-models
      """)
    end
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
