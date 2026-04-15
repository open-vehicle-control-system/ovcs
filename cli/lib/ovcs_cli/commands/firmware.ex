defmodule OvcsCli.Commands.Firmware do
  @moduledoc "Shared plumbing for build/burn/upload: resolve env + shell out."

  alias OvcsCli.{Shell, Vehicles}

  @firmware_dir %{
    "vms" => "vms/firmware",
    "infotainment" => "infotainment/firmware",
    "radio-control-bridge" => "bridges/radio_control_bridge/firmware",
    "ros-bridge" => "bridges/ros_bridge/firmware"
  }

  @nerves_target_side %{
    "vms" => :vms,
    "infotainment" => :infotainment
  }

  def dispatch!(repo_root, vehicle_dir, application, cmd) do
    firmware_path = Map.fetch!(@firmware_dir, application)
    vehicle = find_vehicle!(repo_root, vehicle_dir)
    env = build_env(vehicle, application)
    Shell.run!(cmd, dir: Path.join(repo_root, firmware_path), env: env)
  end

  defp find_vehicle!(repo_root, vehicle_dir) do
    vehicles = Vehicles.list(repo_root)

    case Enum.find(vehicles, &(&1.dir == vehicle_dir)) do
      nil -> raise "Unknown vehicle #{inspect(vehicle_dir)}"
      vehicle -> vehicle
    end
  end

  defp build_env(vehicle, application) do
    base = %{"VEHICLE" => vehicle.module}

    case Map.get(@nerves_target_side, application) do
      nil -> base
      side ->
        case Vehicles.nerves_target(vehicle, side) do
          nil -> base
          target -> Map.put(base, "MIX_TARGET", target)
        end
    end
  end
end
