import Config

vehicle_name = System.get_env("VEHICLE")

if vehicle_name do
  vehicle = Module.concat([vehicle_name])
  vms = vehicle.vms()
  mapping_string = System.get_env("CAN_NETWORK_MAPPINGS") || vms.default_can_mapping(:target)

  config :cantastic,
    can_network_mappings: {
      VmsFirmware.Util.NetworkMapper,
      :can_network_mappings,
      [mapping_string]
    }
end
