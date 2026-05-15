import Config

case OvcsVehicle.Firmware.resolve_bridge(
       __DIR__,
       config_env(),
       System.get_env("BRIDGE_FIRMWARE_ID") ||
         Application.compile_env(:ovcs_bridge, :firmware_id),
       System.get_env("VEHICLE") ||
         Application.compile_env(:ovcs_bridge, :vehicle)
     ) do
  nil ->
    :ok

  {vehicle, bridge_firmware_id, entry} ->
    config :ovcs_vehicle, :module, vehicle

    mapping_string =
      System.get_env("CAN_NETWORK_MAPPINGS") ||
        (entry[:default_can_mapping] || %{target: ""})
        |> Map.get(:target, "")

    config :cantastic,
      can_network_mappings: {
        BridgeFirmware.Util.NetworkMapper,
        :can_network_mappings,
        [mapping_string]
      }

    # Vehicle may override the per-bridge YAML path; otherwise follow
    # the convention `can/bridges/<id>.yml`. Runtime.exs runs after
    # host.exs / target.exs, so this is the single source of truth.
    priv_path = entry[:can_config_path] || "can/bridges/#{bridge_firmware_id}.yml"
    config :cantastic, priv_can_config_path: priv_path

    # See `vms/firmware/config/runtime.exs` for the rationale.
    if Application.spec(:nerves_ssh, :vsn) do
      if dir = OvcsVehicle.Firmware.ssh_system_dir(vehicle, "bridges/#{bridge_firmware_id}") do
        config :nerves_ssh, system_dir: String.to_charlist(dir)
      end
    end
end
