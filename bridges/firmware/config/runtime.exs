import Config

vehicle_name = System.get_env("VEHICLE")
bridge_firmware_id = System.get_env("BRIDGE_FIRMWARE_ID")

if vehicle_name && bridge_firmware_id && config_env() != :test do
  vehicle = Module.concat([vehicle_name])
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

  # Override priv_can_config_path if the vehicle declared one in its
  # bridge_firmwares/0 entry (convention path set in target.exs still
  # applies if :can_config_path is not given).
  case entry[:can_config_path] do
    nil -> :ok
    path -> config :cantastic, priv_can_config_path: path
  end
end
