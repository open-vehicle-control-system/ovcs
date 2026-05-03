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
      archives: [nerves_bootstrap: "~> 1.13"],
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
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:observer_cli, "~> 1.8"},
      {:nerves_runtime, "~> 0.13.0"},
      {:nerves_pack, "~> 0.7.0", targets: @all_targets},
      {:vms_api, path: "../api"},
      # VMS YAMLs reference `import!:@ovcs_can:...` shared frame
      # definitions, so the app must be loaded in the BEAM.
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      # `OvcsVehicle.Firmware.resolve_vehicle/3` is used from
      # `config/runtime.exs` to prepend the vehicle's ebin.
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {
        :ovcs_base_can_system_rpi4,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi4",
        runtime: false,
        targets: :ovcs_base_can_system_rpi4,
        nerves: [compile: false]
      },
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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

  # Copy the selected vehicle's compiled OTP app (ebin + priv + .app)
  # into the release as `lib/<vehicle_dir>-<vsn>/`. The vehicle is its
  # own Mix project under `vehicles/<dir>/` and not a Mix dep here (the
  # dep arrow points the other way), so without this step the vehicle's
  # files never make it into the release.
  #
  # We need the full app tree, not just `.beam` files: Cantastic and
  # other libraries call `Application.app_dir(:<vehicle>, "priv")` to
  # find the CAN topology YAMLs, which requires:
  #   1. A `priv/` dir in the right place.
  #   2. The app loaded via `:application.load/1` so `:code.priv_dir/1`
  #      doesn't return `{:error, :bad_name}`.
  #
  # `./ovcs build` compiles the vehicle for MIX_TARGET=host beforehand;
  # the beams are pure Elixir and run fine on the Nerves target.
  # `OvcsVehicle.Firmware.resolve_vehicle/3` adds the ebin to the code
  # path and calls `:application.load/1` at boot.
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

      # Copy ebin/ and priv/ only — NOT `consolidated/`. The vehicle is
      # compiled with `MIX_TARGET=host` (it's pure Elixir), so its
      # protocol-consolidation output reflects the host dep tree, which
      # excludes target-only deps like vintage_net (gated behind
      # `targets: @all_targets`). Copying the vehicle's
      # `consolidated/Elixir.Collectable.beam` over the release's correct
      # one shadows the target-built version that includes vintage_net's
      # impls — runtime then sees `Collectable not implemented for
      # %VintageNet.Interface.OutputLogger{}` and `ip` commands crash.
      #
      # `cp -rL` to dereference symlinks: Mix's `_build/<env>/lib/<app>/priv`
      # is a symlink to the source `priv/`; without `-L` we'd ship a
      # broken absolute symlink in the release.
      for sub <- ["ebin", "priv"] do
        sub_src = Path.join(src, sub)

        if File.exists?(sub_src) do
          {_, 0} = System.cmd("cp", ["-rL", sub_src, Path.join(dst, sub)])
        end
      end

      Mix.shell().info("Bundled vehicle #{vehicle_name} (ebin + priv) from #{src} → #{dst}")
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
