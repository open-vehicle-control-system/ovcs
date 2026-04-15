import Config

# Compile-time config for running OBD2 locally via
# `cd vehicles/obd2 && iex -S mix` (or `./ovcs run obd2`).
# Firmware builds go through the per-side Nerves projects.

config :vms_core, :vehicle, Obd2.Vms.Composer
config :infotainment_core, :vehicle, Obd2.Infotainment.Composer

# Cantastic: two buses (obd2 + ovcs) and both side YAMLs merged.
config :cantastic,
  otp_app: :obd2,
  priv_can_config_path: ["can/vms.yml", "can/infotainment.yml"],
  setup_can_interfaces: false,
  enable_socketcand: false,
  can_network_mappings: [
    {"obd2", "vcan0"},
    {"ovcs", "vcan1"}
  ]

import_config "../../../vms/api/config/config.exs"
import_config "../../../infotainment/api/config/config.exs"

config :vms_api, VmsApiWeb.Endpoint, server: true
config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true
