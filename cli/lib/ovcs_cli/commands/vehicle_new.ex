defmodule OvcsCli.Commands.VehicleNew do
  @moduledoc """
  Scaffold a new vehicle package under `vehicles/<name>/` from the
  template bundled in `ovcs_vehicle`.
  """

  alias OvcsCli.Vehicles

  @name_pattern ~r/^[a-z][a-z0-9_]*$/
  @target_pattern ~r/^[a-z][a-z0-9_]*$/

  def run(repo_root, raw_name, opts) do
    name = raw_name |> to_string() |> String.trim() |> String.downcase()

    unless Regex.match?(@name_pattern, name) do
      abort("Invalid vehicle name #{inspect(name)}; use snake_case (e.g. my_vehicle).")
    end

    infotainment? = not Map.get(opts, :no_infotainment, false)
    vms_target = validate_target!(opts[:vms_target], "--vms-target")

    infotainment_target =
      if infotainment?,
        do: validate_target!(opts[:infotainment_target], "--infotainment-target"),
        else: nil

    target_dir = Path.join([repo_root, "vehicles", name])

    assigns = [
      module: Vehicles.module_for(name),
      name: name,
      upper: String.upcase(name),
      vms_target: vms_target,
      infotainment_target: infotainment_target,
      infotainment: infotainment?
    ]

    case OvcsVehicle.Scaffold.generate(target_dir, assigns, repo_root: repo_root) do
      :ok ->
        rel = Path.relative_to(target_dir, repo_root)
        IO.puts(IO.ANSI.green() <> "Scaffolded " <> rel <> IO.ANSI.reset())
        IO.puts("")
        IO.puts("Targets:")
        IO.puts("  vms          → #{vms_target}")
        IO.puts("  infotainment → #{infotainment_target || "(skipped)"}")

        warn_missing_firmware(repo_root, :vms, vms_target)
        if infotainment_target, do: warn_missing_firmware(repo_root, :infotainment, infotainment_target)

        IO.puts("")
        IO.puts("Next steps:")
        IO.puts("  ./ovcs build #{name} vms         # build VMS firmware")

        if infotainment_target do
          IO.puts("  ./ovcs build #{name} infotainment # build infotainment firmware")
        end

        IO.puts("  ./ovcs can setup #{name}         # provision host vcan interfaces")

        IO.puts("")
        IO.puts("Then review lib/#{name}.ex and composers; prune components and")
        IO.puts("CAN configs you don't need. See #{rel}/README.md for details.")

      {:error, {:template_missing, path}} ->
        abort("Template missing: #{path} (recompile ovcs_vehicle)")
    end
  end

  defp validate_target!(value, flag) do
    target = value |> to_string() |> String.trim()

    unless Regex.match?(@target_pattern, target) do
      abort("Invalid #{flag} value #{inspect(target)}; expected a Nerves target atom " <>
              "name like ovcs_base_can_system_rpi4.")
    end

    target
  end

  defp warn_missing_firmware(repo_root, side, target) do
    dir = OvcsVehicle.Scaffold.firmware_defaults_dir(repo_root, side, target)

    unless File.dir?(dir) do
      rel = Path.relative_to(dir, repo_root)

      IO.puts("")
      IO.puts(
        IO.ANSI.yellow() <>
          "Note: no firmware defaults for #{side} target #{target} at #{rel}.\n" <>
          "      priv/firmware/#{side}/ was not populated — seed one by dropping\n" <>
          "      fwup.conf + config.txt in there, or add them to the shared\n" <>
          "      target dir so future scaffolds pick them up." <> IO.ANSI.reset()
      )
    end
  end

  defp abort(message) do
    IO.puts(:stderr, IO.ANSI.red() <> message <> IO.ANSI.reset())
    System.halt(1)
  end
end
