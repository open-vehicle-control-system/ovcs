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
      # EXLA needs Nx 1.0; evision, through vision_core, asks for < 1.0.
      {:nx, "~> 1.0", override: true},
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
       tag: "v0.3.0",
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

  # The vehicle is its own Mix project, not a dep: its app is copied into the release.
  defp copy_vehicle_app(release) do
    if vehicle_name = System.get_env("VEHICLE") do
      vehicle_directory = Macro.underscore(vehicle_name)

      vehicle_app_path =
        Path.expand(
          "../../vehicles/#{vehicle_directory}/_build/dev/lib/#{vehicle_directory}",
          __DIR__
        )

      unless File.dir?(vehicle_app_path) do
        Mix.raise("""
        Vehicle app dir not found at:

            #{vehicle_app_path}

        Compile the vehicle first (the `./ovcs build` helper does this
        for you):

            (cd vehicles/#{vehicle_directory} && MIX_TARGET=host mix compile)
        """)
      end

      version = read_app_version!(vehicle_app_path, vehicle_directory)
      release_app_path = Path.join([release.path, "lib", "#{vehicle_directory}-#{version}"])

      File.rm_rf!(release_app_path)
      File.mkdir_p!(release_app_path)

      # ebin/ and priv/ only, not consolidated/: see vms/firmware/mix.exs.
      # `cp -rL` dereferences the priv/ symlink in `_build`.
      for subdirectory <- ["ebin", "priv"] do
        source = Path.join(vehicle_app_path, subdirectory)

        if File.exists?(source) do
          {_, 0} = System.cmd("cp", ["-rL", source, Path.join(release_app_path, subdirectory)])
        end
      end

      Mix.shell().info(
        "Bundled vehicle #{vehicle_name} (ebin + priv) from #{vehicle_app_path} → #{release_app_path}"
      )

      check_required_files!(vehicle_name, vehicle_app_path, release_app_path)
    end

    release
  end

  # A vision unit missing a file its composer requires boots but cannot do its job.
  defp check_required_files!(vehicle_name, vehicle_app_path, release_app_path) do
    Code.prepend_path(Path.join(vehicle_app_path, "ebin"))
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

    missing = Enum.reject(required_files, &File.exists?(Path.join(release_app_path, &1)))

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

  defp read_app_version!(app_path, app_name) do
    app_file = Path.join([app_path, "ebin", "#{app_name}.app"])

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, _name, properties}]} ->
        case Keyword.fetch(properties, :vsn) do
          {:ok, version} -> List.to_string(version)
          :error -> Mix.raise("No :vsn in #{app_file}")
        end

      failure ->
        Mix.raise("Could not read #{app_file}: #{inspect(failure)}")
    end
  end
end
