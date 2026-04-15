defmodule OvcsCli.Commands.Firmware do
  @moduledoc """
  Shared plumbing for build/burn/upload/clean: resolve firmware dir +
  env vars for a given (vehicle, application) pair and shell out.

  `application` is either:
    * `"vms"` / `"infotainment"` — static per-side firmwares with
      their own directories and `nerves_target/1` wiring;
    * any key from the vehicle's `bridge_firmwares/0` map — dispatches
      to the shared `bridges/firmware` with `BRIDGE_FIRMWARE_ID` set
      and `MIX_TARGET` pulled from the vehicle's entry.
  """

  alias OvcsCli.{Shell, Vehicles}

  @static_firmware_dir %{
    "vms" => "vms/firmware",
    "infotainment" => "infotainment/firmware"
  }

  @static_target_side %{
    "vms" => :vms,
    "infotainment" => :infotainment
  }

  @bridges_firmware_dir "bridges/firmware"

  @doc "Static application ids always valid for every vehicle."
  def static_applications, do: Map.keys(@static_firmware_dir)

  @doc """
  Valid application ids for a given vehicle: static ones plus any
  bridge firmware ids declared in `bridge_firmwares/0`.
  """
  @spec applications_for(Vehicles.t()) :: [String.t()]
  def applications_for(vehicle) do
    static =
      Enum.filter(static_applications(), fn app ->
        side = Map.fetch!(@static_target_side, app)
        Vehicles.nerves_target(vehicle, side) != nil
      end)

    static ++ Map.keys(Vehicles.bridge_firmwares(vehicle))
  end

  def dispatch!(repo_root, vehicle_dir, application, cmd) do
    vehicle = find_vehicle!(repo_root, vehicle_dir)
    {firmware_path, env} = resolve!(vehicle, application)
    Shell.run!(cmd, dir: Path.join(repo_root, firmware_path), env: env)
  end

  defp resolve!(vehicle, application) do
    cond do
      Map.has_key?(@static_firmware_dir, application) ->
        {
          Map.fetch!(@static_firmware_dir, application),
          static_env(vehicle, application)
        }

      true ->
        bridge_env!(vehicle, application)
    end
  end

  defp static_env(vehicle, application) do
    base = %{"VEHICLE" => vehicle.module}
    side = Map.fetch!(@static_target_side, application)

    case Vehicles.nerves_target(vehicle, side) do
      nil -> base
      target -> Map.put(base, "MIX_TARGET", target)
    end
  end

  defp bridge_env!(vehicle, application) do
    case Map.fetch(Vehicles.bridge_firmwares(vehicle), application) do
      {:ok, %{target: target}} ->
        env = %{
          "VEHICLE" => vehicle.module,
          "BRIDGE_FIRMWARE_ID" => application,
          "MIX_TARGET" => target
        }

        {@bridges_firmware_dir, env}

      :error ->
        raise """
        Unknown application #{inspect(application)} for vehicle #{vehicle.dir}.
        Expected one of: #{Enum.join(static_applications() ++ Map.keys(Vehicles.bridge_firmwares(vehicle)), ", ")}
        """
    end
  end

  defp find_vehicle!(repo_root, vehicle_dir) do
    vehicles = Vehicles.list(repo_root)

    case Enum.find(vehicles, &(&1.dir == vehicle_dir)) do
      nil -> raise "Unknown vehicle #{inspect(vehicle_dir)}"
      vehicle -> vehicle
    end
  end
end
