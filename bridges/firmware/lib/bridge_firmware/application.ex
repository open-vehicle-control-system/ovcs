defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application
  require Logger

  # `ovcs_bus_gateway` is not compiled into firmwares for targets it does not support.
  @compile {:no_warn_undefined, OvcsBusGateway}

  @build_target Application.compile_env(:ovcs_bridge, :build_target, :host)

  @impl Application
  def start(_type, _args) do
    children = target_guards() ++ [{OvcsBridge.Supervisor, []}] ++ bus_gateway_child()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end

  # On host (`./ovcs run`) stop nerves_uevent — its netlink port
  # crash-loops on a dev host's coldplug uevents and isn't used off
  # target. See `OvcsVehicle.HostUEventGuard`.
  #
  # On target, mark the firmware valid so an A/B update sticks: the v2.0
  # systems revert to the previous slot on next boot otherwise. See
  # `OvcsVehicle.FirmwareValidator`.
  defp target_guards do
    if Nerves.Runtime.mix_target() == :host,
      do: [OvcsVehicle.HostUEventGuard],
      else: [OvcsVehicle.FirmwareValidator]
  end

  # The gateway of the entry's `bus_gateway:` config; on host its app is `runtime: false`.
  defp bus_gateway_child do
    {vehicle, firmware_id, entry} = OvcsBridge.firmware_entry()

    with config when not is_nil(config) <- entry[:bus_gateway],
         {:ok, _apps} <- Application.ensure_all_started(:ovcs_bus_gateway) do
      mqtt_client_id =
        "ovcs_bus_gateway_#{OvcsBusGateway.vehicle_id(vehicle)}_#{firmware_id}_#{@build_target}"

      opts = [vehicle: vehicle, config: config, mqtt_client_id: mqtt_client_id]
      [%{OvcsBusGateway.child_spec(opts) | start: {__MODULE__, :start_bus_gateway, [opts]}}]
    else
      nil ->
        []

      {:error, reason} ->
        Logger.error("Bus gateway not started: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Starts the `OvcsBusGateway` subtree for `opts`. A gateway that cannot start
  is logged and ignored, so the bridges keep running.
  """
  @spec start_bus_gateway(keyword()) :: Supervisor.on_start() | :ignore
  def start_bus_gateway(opts) do
    {module, function, args} = OvcsBusGateway.child_spec(opts).start

    case apply(module, function, args) do
      {:error, reason} ->
        Logger.error("Bus gateway not started: #{inspect(reason)}")
        :ignore

      started ->
        started
    end
  end
end
