import Config

vehicle_name = System.get_env("VEHICLE") || raise "VEHICLE env var is required for firmware builds"
bridge_firmware_id =
  System.get_env("BRIDGE_FIRMWARE_ID") ||
    raise "BRIDGE_FIRMWARE_ID env var is required for firmware builds"

# Cantastic's per-bridge-firmware YAML path follows a convention
# (`can/bridges/<id>.yml`) unless the vehicle overrides it in
# bridge_firmwares/0. Priv path is resolved at runtime below; here we
# stamp the otp_app so cantastic knows where to look.
vehicle_dir = Macro.underscore(vehicle_name)

# Per-vehicle environment overrides (SSH keys, Wi-Fi creds, Phoenix
# secrets). Lives at `vehicles/<vehicle_dir>/.env.exs` so the same
# values are picked up by every firmware (vms, infotainment, bridges)
# of one vehicle. Gitignored.
if config_env() in [:dev, :test, :prod] do
  for filename <- [".env.exs", ".env.#{config_env()}.exs"] do
    abs = Path.expand("../../../vehicles/#{vehicle_dir}/#{filename}", __DIR__)
    if File.exists?(abs), do: import_config(abs)
  end
end

config :cantastic,
  otp_app: String.to_atom(vehicle_dir),
  priv_can_config_path: "can/bridges/#{bridge_firmware_id}.yml"

# Override nerves_pack's default usb0+eth0 to optionally add wlan0
# based on `WIFI_NETWORKS` (set in the vehicle's `.env.exs`). See
# vms/firmware/config/target.exs for why this can't go through a
# helper module.
wifi_networks =
  case System.get_env("WIFI_NETWORKS") do
    blank when blank in [nil, ""] ->
      []

    src ->
      {parsed, _} = Code.eval_string(src)

      Enum.map(parsed, fn {ssid, psk} ->
        %{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}
      end)
  end

wlan0_config =
  case wifi_networks do
    [] ->
      []

    networks ->
      [
        {"wlan0",
         %{
           type: VintageNetWiFi,
           vintage_net_wifi: %{networks: networks},
           ipv4: %{method: :dhcp}
         }}
      ]
  end

config :vintage_net,
  regulatory_domain: "00",
  config:
    [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :dhcp}
       }}
    ] ++ wlan0_config
