defmodule OvcsCli do
  @moduledoc """
  Entry point for the `ovcs` command-line tool.

  Drives builds, burns, OTA uploads, and vehicle introspection by shelling
  out to `mix` with the right `VEHICLE` / `MIX_TARGET` env vars resolved
  from each vehicle package's `OvcsVehicle` implementation.
  """

  alias OvcsCli.{Commands, Prompt, Vehicles}

  @applications ~w(vms infotainment radio-control-bridge ros-bridge)

  def main(argv) do
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
          clean: clean_spec(vehicle_names)
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

      _ ->
        Optimus.parse!(optimus, ["--help"])
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

  defp vehicle_and_application_args(vehicles) do
    [
      vehicle: [
        value_name: "VEHICLE",
        help:
          "Vehicle directory (#{Enum.join(vehicles, " | ")}). Prompts if omitted.",
        required: false,
        parser: fn value ->
          if value in vehicles do
            {:ok, value}
          else
            {:error, "unknown vehicle #{inspect(value)} (known: #{Enum.join(vehicles, ", ")})"}
          end
        end
      ],
      application: [
        value_name: "APPLICATION",
        help:
          "Application (#{Enum.join(@applications, " | ")}). Prompts if omitted.",
        required: false,
        parser: fn value ->
          if value in @applications do
            {:ok, value}
          else
            {:error, "unknown application #{inspect(value)} (known: #{Enum.join(@applications, ", ")})"}
          end
        end
      ]
    ]
  end

  defp resolve_vehicle_app(%{vehicle: v, application: a}, vehicles) do
    vehicle = v || Prompt.choose!("vehicle", vehicles)
    application = a || Prompt.choose!("application", @applications)
    {vehicle, application}
  end

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
