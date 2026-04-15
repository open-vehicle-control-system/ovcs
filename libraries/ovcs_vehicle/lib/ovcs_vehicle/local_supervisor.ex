defmodule OvcsVehicle.LocalSupervisor do
  @moduledoc """
  Shared supervisor for running a vehicle package as its own local-
  dev BEAM (`cd vehicles/<name> && iex -S mix`). Each vehicle's
  `Application` module starts this supervisor passing its own
  top-level module (the one implementing `OvcsVehicle`).

  Responsibilities:
    * call `children/0` on every bridge bundled in every
      `bridge_firmwares/0` entry and start them as a flat list,
      with child ids namespaced by `{module, firmware_id}` so two
      firmwares bundling the same bridge don't collide.

  vms_core / infotainment_core auto-start via their own OTP apps
  (they're deps of the vehicle package); this module only handles
  the bridges, which have no global Application of their own.

  Cross-firmware MQTT relay is skipped in local mode — everything
  runs in one BEAM, so the node-local `OvcsBus` fans out to every
  side already.
  """
  use Supervisor
  require Logger

  def start_link(vehicle_module) when is_atom(vehicle_module) do
    Supervisor.start_link(__MODULE__, vehicle_module,
      name: Module.concat(vehicle_module, "LocalSupervisor")
    )
  end

  @impl true
  def init(vehicle_module) do
    Supervisor.init(bridge_children(vehicle_module), strategy: :one_for_one)
  end

  defp bridge_children(vehicle_module) do
    firmwares =
      if function_exported?(vehicle_module, :bridge_firmwares, 0),
        do: vehicle_module.bridge_firmwares(),
        else: %{}

    Enum.flat_map(firmwares, fn {firmware_id, entry} ->
      bridges = Map.get(entry, :bridges, [])

      Logger.info(
        "OvcsVehicle.LocalSupervisor starting bridge firmware " <>
          "#{inspect(firmware_id)} with: " <>
          "#{Enum.map_join(bridges, ", ", &inspect/1)}"
      )

      Enum.flat_map(bridges, fn bridge -> namespace(bridge.children(), firmware_id) end)
    end)
  end

  defp namespace(specs, firmware_id) do
    Enum.map(specs, fn
      {module, arg} -> %{id: {module, firmware_id}, start: {module, :start_link, [arg]}}
      module when is_atom(module) -> %{id: {module, firmware_id}, start: {module, :start_link, [[]]}}
      %{id: id} = spec -> %{spec | id: {id, firmware_id}}
    end)
  end
end
