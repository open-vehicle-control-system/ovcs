import Config

# Compile-time config for running OVCS Mini locally via
# `cd vehicles/ovcs_mini && iex -S mix` (or `./ovcs run ovcs_mini`).
# Firmware builds go through `vms/firmware`, never here.

config :vms_core, :vehicle, OvcsMini.Vms.Composer

# Cantastic: one OVCS bus, vms.yml only (OVCS Mini has no
# infotainment side).
config :cantastic,
  otp_app: :ovcs_mini,
  priv_can_config_path: "can/vms.yml",
  setup_can_interfaces: false,
  enable_socketcand: false,
  can_network_mappings: [{"ovcs", "vcan0"}]

# Pull in the VMS API endpoint + repo config.
import_config "../../../vms/api/config/config.exs"

# Serve the VMS API + debug dashboard under plain `iex -S mix`.
config :vms_api, VmsApiWeb.Endpoint, server: true
