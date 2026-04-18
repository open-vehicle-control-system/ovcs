import Config

vehicle_name = System.get_env("VEHICLE")
bridge_firmware_id = System.get_env("BRIDGE_FIRMWARE_ID")

# Host runs us from `bridges/firmware/` without pulling the vehicle as a
# Mix dep — add its compiled ebin before we dereference the module.
# Nerves target builds ship the vehicle inside the release, so this
# prepend is a cheap no-op there.
if vehicle_name do
  dir = Macro.underscore(vehicle_name)
  ebin = Path.expand("../../../vehicles/#{dir}/_build/#{config_env()}/lib/#{dir}/ebin", __DIR__)
  Code.prepend_path(ebin)
end

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

  # Vehicle may override the per-bridge YAML path; otherwise follow the
  # convention `can/bridges/<id>.yml`. Runtime.exs runs after host.exs /
  # target.exs, so this is the single source of truth for the path.
  priv_path = entry[:can_config_path] || "can/bridges/#{bridge_firmware_id}.yml"
  config :cantastic, priv_can_config_path: priv_path
end
