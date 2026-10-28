defmodule OvcsBridge do
  @moduledoc """
  Contract every OVCS bridge library implements.

  A "bridge" is a focused library (radio-control, ROS, lidar, …)
  that exposes a supervision subtree via `children/0`. The shared
  Nerves firmware at `bridges/firmware/` composes one or more
  bridges per image — the set is declared per vehicle via
  `OvcsVehicle.bridge_firmwares/0` so a single vehicle can run
  multiple bridge firmwares in parallel (e.g. one rpi3a image for
  radio-control and one rpi5 image for ROS + lidar).

  Bridge libraries get `OvcsBus` pub/sub for free — pulling in
  `ovcs_bridge` brings `ovcs_bus` along, so a bridge child can
  `OvcsBus.subscribe("messages")` / `OvcsBus.broadcast/2` exactly
  like any `vms_core` component. A broadcast stays on the bridge's
  BEAM (see `OvcsBus`).

  Keep the behaviour tight — anything vehicle-specific belongs in
  the vehicle's `bridge_firmwares/0` entry (target, CAN config,
  default mapping, …), not baked into the bridge library.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]

  @doc """
  Optional hook invoked from `bridges/firmware`'s `config/runtime.exs`
  before any application starts. Bridges that need to stamp
  third-party Application env from per-vehicle config (e.g. a serial
  protocol library that reads its UART pin once at boot) implement
  this; the firmware host walks every bundled bridge and calls the
  callback on whichever ones export it.

  The bridge is responsible for reading its own vehicle config and
  writing whatever env keys its dependencies expect via
  `Application.put_env(app, key, value, persistent: true)`. Keep
  this small — anything that can wait until `children/0` should
  live there instead.
  """
  @callback apply_runtime_config(vehicle :: module(), build_target :: atom()) :: any()

  @optional_callbacks apply_runtime_config: 2

  @doc """
  The active bridge firmware: `{vehicle, firmware_id, entry}`, `entry`
  being the vehicle's `bridge_firmwares/0` entry for `firmware_id`.

  `VEHICLE` and `BRIDGE_FIRMWARE_ID` win over the `:ovcs_bridge`
  `:vehicle` and `:firmware_id` baked at build time: on the host every
  bridge BEAM shares one build, and each is launched with its own env.
  Raises when either is unset or the entry does not exist.
  """
  @spec firmware_entry() :: {module(), String.t(), OvcsVehicle.bridge_firmware()}
  def firmware_entry do
    vehicle = vehicle_module()
    firmware_id = firmware_id()

    case Map.fetch(vehicle.bridge_firmwares(), firmware_id) do
      {:ok, entry} ->
        {vehicle, firmware_id, entry}

      :error ->
        raise """
        OvcsBridge: no entry #{inspect(firmware_id)} in #{inspect(vehicle)}.bridge_firmwares/0.
        Known ids: #{Map.keys(vehicle.bridge_firmwares()) |> Enum.join(", ")}
        """
    end
  end

  defp vehicle_module do
    name =
      System.get_env("VEHICLE") || Application.get_env(:ovcs_bridge, :vehicle) ||
        raise "OvcsBridge: :vehicle not set (set VEHICLE at build/run time)"

    Module.concat([name])
  end

  defp firmware_id do
    System.get_env("BRIDGE_FIRMWARE_ID") ||
      Application.get_env(:ovcs_bridge, :firmware_id) ||
      raise "OvcsBridge: firmware id not set (set BRIDGE_FIRMWARE_ID env or :ovcs_bridge :firmware_id)"
  end
end
