defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    bridges =
      case Application.get_env(:firmware, :target) do
        :host -> []
        _ -> resolve_bridges()
      end

    children =
      Enum.flat_map(bridges, fn bridge -> bridge.children() end)

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end

  defp resolve_bridges do
    vehicle_name =
      Application.get_env(:bridge_firmware, :vehicle) ||
        raise "BridgeFirmware: :vehicle not set in app env"

    firmware_id =
      Application.get_env(:bridge_firmware, :bridge_firmware_id) ||
        raise "BridgeFirmware: :bridge_firmware_id not set in app env"

    vehicle = Module.concat([vehicle_name])

    case Map.fetch(vehicle.bridge_firmwares(), firmware_id) do
      {:ok, %{bridges: bridges}} ->
        Logger.info(
          "BridgeFirmware starting #{vehicle_name}/#{firmware_id} with: #{Enum.map_join(bridges, ", ", &inspect/1)}"
        )

        bridges

      :error ->
        raise "BridgeFirmware: no entry #{inspect(firmware_id)} in #{vehicle_name}.bridge_firmwares/0"
    end
  end
end
