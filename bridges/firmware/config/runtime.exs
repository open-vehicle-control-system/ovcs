import Config

vehicle = OvcsVehicle.Firmware.resolve_vehicle(__DIR__, config_env())
bridge_firmware_id = System.get_env("BRIDGE_FIRMWARE_ID")

if vehicle && bridge_firmware_id && config_env() != :test do
  entry = Map.fetch!(vehicle.bridge_firmwares(), bridge_firmware_id)

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

  # Vehicle may override the per-bridge YAML path; otherwise follow the
  # convention `can/bridges/<id>.yml`. Runtime.exs runs after host.exs /
  # target.exs, so this is the single source of truth for the path.
  priv_path = entry[:can_config_path] || "can/bridges/#{bridge_firmware_id}.yml"
  config :cantastic, priv_can_config_path: priv_path
end
