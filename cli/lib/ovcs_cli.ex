defmodule OvcsCli do
  @moduledoc """
  Entry point for the `ovcs` command-line tool.

  Drives builds, burns, OTA uploads, and vehicle introspection by shelling
  out to `mix` with the right `VEHICLE` / `MIX_TARGET` env vars resolved
  from each vehicle package's `OvcsVehicle` implementation.
  """

  alias OvcsCli.{Commands, Prompt, Vehicles}

  # Static applications are always valid for every vehicle. Bridge
  # firmware ids are declared per-vehicle via
  # `OvcsVehicle.bridge_firmwares/0` and discovered lazily in
  # `resolve_vehicle_app/2`.
  @static_applications Commands.Firmware.static_applications()

  def main(argv) do
    argv = normalize_help(argv)
    vehicles = Vehicles.list(repo_root())
    vehicle_names = Enum.map(vehicles, & &1.dir)

    optimus =
      Optimus.new!(
        name: "ovcs",
        description: "OVCS vehicle/firmware orchestrator",
        version: "0.1.0",
        about: "Build, burn, upload, and inspect OVCS vehicle firmware.",
        allow_unknown_args: false,
        parse_double_dash: true,
        subcommands: [
          vehicles: [
            name: "vehicles",
            about: "List discovered vehicles and their Nerves targets"
          ],
          doctor: [
            name: "doctor",
            about: "Verify toolchain and vehicle packages"
          ],
          build: build_spec(vehicle_names),
          burn: burn_spec(vehicle_names),
          upload: upload_spec(vehicle_names),
          clean: clean_spec(vehicle_names),
          can: can_spec(vehicle_names),
          vehicle: vehicle_spec()
        ]
      )

    case Optimus.parse!(optimus, argv) do
      {[:vehicles], _} ->
        Commands.Vehicles.run(repo_root(), vehicles)

      {[:doctor], _} ->
        Commands.Doctor.run(repo_root())

      {[:build], %{args: args}} ->
        {v, a} = resolve_vehicle_app(args, vehicle_names)
        Commands.Build.run(repo_root(), v, a)

      {[:burn], %{args: args}} ->
        {v, a} = resolve_vehicle_app(args, vehicle_names)
        Commands.Burn.run(repo_root(), v, a)

      {[:upload], %{args: args, options: opts}} ->
        {v, a} = resolve_vehicle_app(args, vehicle_names)
        Commands.Upload.run(repo_root(), v, a, opts)

      {[:clean], %{args: args}} ->
        {v, a} = resolve_vehicle_app(args, vehicle_names)
        Commands.Clean.run(repo_root(), v, a)

      {[:can, :setup], %{args: %{vehicle: v}}} ->
        vehicle = v || Prompt.choose!("vehicle", vehicle_names)
        Commands.Can.setup(repo_root(), vehicle)

      {[:can, :status], %{args: %{vehicle: v}}} ->
        vehicle = v || Prompt.choose!("vehicle", vehicle_names)
        Commands.Can.status(repo_root(), vehicle)

      {[:can], _} ->
        Optimus.parse!(optimus, ["help", "can"])

      {[:vehicle, :new], %{args: %{name: name}, options: opts, flags: flags}} ->
        Commands.VehicleNew.run(repo_root(), name, Map.merge(opts, flags))

      {[:vehicle], _} ->
        Optimus.parse!(optimus, ["help", "vehicle"])

      _ ->
        Optimus.parse!(optimus, ["--help"])
    end
  end

  # Rewrite `./ovcs <sub> [subsub] --help` (and `-h`) into
  # `./ovcs help <sub> [subsub]` so the nested help path works uniformly
  # whichever convention the user reaches for.
  defp normalize_help(argv) do
    case Enum.split_with(argv, &(&1 in ["--help", "-h"])) do
      {[], _} -> argv
      {_, rest} when rest == [] -> ["--help"]
      {_, rest} -> ["help" | rest]
    end
  end

  defp build_spec(vehicles) do
    [
      name: "build",
      about: "Build firmware for a vehicle/application",
      args: vehicle_and_application_args(vehicles)
    ]
  end

  defp burn_spec(vehicles) do
    [
      name: "burn",
      about: "Burn firmware to an SD card for a vehicle/application",
      args: vehicle_and_application_args(vehicles)
    ]
  end

  defp can_spec(vehicles) do
    vehicle_arg = [
      vehicle: [
        value_name: "VEHICLE",
        help: "Vehicle directory (prompts if omitted)",
        required: false,
        parser: fn value ->
          if value in vehicles,
            do: {:ok, value},
            else: {:error, "unknown vehicle #{inspect(value)}"}
        end
      ]
    ]

    [
      name: "can",
      about: "Host CAN helpers",
      subcommands: [
        setup: [
          name: "setup",
          about: "Create + bring up the vcan interfaces a vehicle needs",
          args: vehicle_arg
        ],
        status: [
          name: "status",
          about: "Report which vcan interfaces a vehicle needs and whether they're up",
          args: vehicle_arg
        ]
      ]
    ]
  end

  defp vehicle_spec do
    [
      name: "vehicle",
      about: "Vehicle package helpers",
      subcommands: [
        new: [
          name: "new",
          about: "Scaffold a new vehicle package from the bundled template",
          args: [
            name: [
              value_name: "NAME",
              help: "New vehicle directory name (snake_case)",
              required: true
            ]
          ],
          options: [
            vms_target: [
              value_name: "TARGET",
              long: "--vms-target",
              help: "Nerves target system for the VMS firmware",
              default: "ovcs_base_can_system_rpi4",
              required: false
            ],
            infotainment_target: [
              value_name: "TARGET",
              long: "--infotainment-target",
              help: "Nerves target system for the infotainment firmware",
              default: "ovcs_base_can_system_rpi5",
              required: false
            ]
          ],
          flags: [
            no_infotainment: [
              long: "--no-infotainment",
              help: "Scaffold a VMS-only vehicle (skip the infotainment side)",
              multiple: false
            ]
          ]
        ]
      ]
    ]
  end

  defp clean_spec(vehicles) do
    [
      name: "clean",
      about: "Remove build artifacts for a vehicle/application",
      args: vehicle_and_application_args(vehicles)
    ]
  end

  defp upload_spec(vehicles) do
    [
      name: "upload",
      about: "OTA-upload firmware to a running device",
      args: vehicle_and_application_args(vehicles),
      options: [
        host: [
          value_name: "HOST",
          short: "-h",
          long: "--host",
          help: "Target host (default: <vehicle>-<application>.local)",
          required: false
        ],
        file: [
          value_name: "FILE",
          short: "-f",
          long: "--file",
          help: "Custom .fw file to push",
          required: false
        ]
      ]
    ]
  end

  # Both positional args accept *either* a vehicle dir or an application
  # name (vms/infotainment or a bridge_firmwares/0 key). Bridge ids are
  # vehicle-dependent, so parsing just enforces a snake/kebab-case shape
  # and final validation happens in resolve_vehicle_app/2 once the
  # vehicle is known.
  @app_token ~r/^[a-z][a-z0-9_-]*$/

  defp vehicle_and_application_args(vehicles) do
    parser = fn value ->
      cond do
        value in vehicles ->
          {:ok, value}

        Regex.match?(@app_token, value) ->
          {:ok, value}

        true ->
          {:error,
           "unknown token #{inspect(value)}; expected a vehicle " <>
             "(#{Enum.join(vehicles, ", ")}) or an application id"}
      end
    end

    [
      first: [
        value_name: "VEHICLE|APP",
        help: "Vehicle or application. Order doesn't matter; missing one is prompted.",
        required: false,
        parser: parser
      ],
      second: [
        value_name: "VEHICLE|APP",
        help: "The other of vehicle/application.",
        required: false,
        parser: parser
      ]
    ]
  end

  defp resolve_vehicle_app(%{first: first, second: second}, vehicle_dirs) do
    values = [first, second] |> Enum.reject(&is_nil/1)
    vehicle_dir = Enum.find(values, &(&1 in vehicle_dirs)) || Prompt.choose!("vehicle", vehicle_dirs)

    vehicle = Vehicles.list(repo_root()) |> Enum.find(&(&1.dir == vehicle_dir))
    valid_apps = Commands.Firmware.applications_for(vehicle)
    remaining = Enum.reject(values, &(&1 == vehicle_dir))

    application =
      case Enum.find(remaining, &(&1 in valid_apps)) do
        nil ->
          case remaining do
            [] -> Prompt.choose!("application", valid_apps)
            [bad | _] ->
              IO.puts(
                IO.ANSI.red() <>
                  "Unknown application #{inspect(bad)} for vehicle #{vehicle_dir}.\n" <>
                  "Valid: #{Enum.join(valid_apps, ", ")}" <>
                  IO.ANSI.reset()
              )

              System.halt(1)
          end

        app ->
          app
      end

    {vehicle_dir, application}
  end

  # Silence "module attribute unused" when resolve_vehicle_app doesn't
  # reference @static_applications directly (kept for documentation
  # and future help text).
  _ = @static_applications

  @doc false
  def repo_root do
    # The escript is typically run from anywhere, but the binary lives at the
    # repo root (symlink). We derive the repo root from either OVCS_ROOT or
    # the current working directory climbing until we see a `vehicles/` dir.
    case System.get_env("OVCS_ROOT") do
      nil -> find_root(File.cwd!())
      path -> path
    end
  end

  defp find_root(dir) do
    cond do
      File.dir?(Path.join(dir, "vehicles")) and File.dir?(Path.join(dir, "libraries")) ->
        dir

      dir == "/" ->
        raise "Could not find OVCS repo root; set OVCS_ROOT or run from within the repo."

      true ->
        find_root(Path.dirname(dir))
    end
  end
end
