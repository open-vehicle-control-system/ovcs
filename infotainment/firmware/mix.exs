defmodule OvcsInfotainmentFirmware.MixProject do
  use Mix.Project

  @app :infotainment_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_base_can_system_rpi5
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
      mod: {InfotainmentFirmware.Application, []},
      included_applications: [:infotainment_api],
      extra_applications: [:logger, :runtime_tools],
      start_phases: [{:load_and_start_apps, []}]
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

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:vintage_net, "~> 0.13", targets: @all_targets},
      {:vintage_net_ethernet, "~> 0.11", targets: @all_targets},
      {:plug_cowboy, "~> 2.0"},
      {:infotainment_api, path: "../api", runtime: false},
      # Infotainment YAMLs reference `import!:@ovcs_can:...` shared
      # frame definitions, so the app must be loaded in the BEAM.
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      # `OvcsVehicle.Firmware.resolve_vehicle/3` is used from
      # `config/runtime.exs` to prepend the vehicle's ebin.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:nerves_flutter_support, "~> 1.3"},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {
        :ovcs_base_can_system_rpi5,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi5",
        runtime: false,
        targets: :ovcs_base_can_system_rpi5,
        nerves: [compile: false]
      },
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [
        &Nerves.Release.init/1,
        &NervesFlutterSupport.InstallRuntime.run/1,
        &NervesFlutterSupport.BuildFlutterApp.run/1,
        :assemble,
        &copy_vehicle_app/1
      ],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]],
      flutter: [project_dir: Path.expand("../dashboard/")]
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
