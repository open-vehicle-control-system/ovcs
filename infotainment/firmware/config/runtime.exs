import Config

vehicle_name = System.get_env("VEHICLE")

if vehicle_name do
  vehicle = Module.concat([vehicle_name])
  infotainment = vehicle.infotainment()
  mapping_string =
    System.get_env("CAN_NETWORK_MAPPINGS") || infotainment.default_can_mapping(:target)

  config :cantastic,
    can_network_mappings: fn ->
      mapping_string
      |> String.split(",", trim: true)
      |> Enum.map(fn i ->
        [network_name, can_interface] = i |> String.split(":", trim: true)
        {network_name, can_interface}
      end)
    end
end
