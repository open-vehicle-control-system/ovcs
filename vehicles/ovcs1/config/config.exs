import Config

# Compile-time config used when the vehicle package is run as its
# own local-dev app (`cd vehicles/ovcs1 && iex -S mix`). Firmware
# builds go through `vms/firmware`, `infotainment/firmware`, or
# `bridges/firmware`, each with its own `config/config.exs`, so
# nothing here affects production images.

# Wire the composers so vms_core and infotainment_core dispatch
# through Ovcs1 without needing the VEHICLE env var.
config :vms_core, :vehicle, Ovcs1.Vms.Composer
config :infotainment_core, :vehicle, Ovcs1.Infotainment.Composer

# Cantastic reads both YAMLs from the vehicle's own priv dir and
# unions same-named networks, letting the single BEAM serve both
# VMS and infotainment sides. Network mappings cover every bus
# declared by Ovcs1.Vms.Composer.default_can_mapping(:host).
config :cantastic,
  otp_app: :ovcs1,
  priv_can_config_path: ["can/vms.yml", "can/infotainment.yml"],
  setup_can_interfaces: false,
  enable_socketcand: false,
  can_network_mappings: [
    {"ovcs", "vcan0"},
    {"leaf_drive", "vcan1"},
    {"polo_drive", "vcan2"},
    {"orion_bms", "vcan3"},
    {"misc", "vcan4"}
  ]

# Pull in the per-side endpoint + repo configs. VMS on :4000,
# infotainment on :4001 (no clash). Each of these imports its own
# `#{config_env()}.exs` at the bottom.
import_config "../../../vms/api/config/config.exs"
import_config "../../../infotainment/api/config/config.exs"

# Start both Phoenix endpoints under plain `iex -S mix` without
# needing `mix phx.server` — listeners on :4000 + :4001 from boot.
config :vms_api, VmsApiWeb.Endpoint, server: true
config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true
