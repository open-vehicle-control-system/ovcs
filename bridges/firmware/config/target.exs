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

config :cantastic,
  otp_app: String.to_atom(vehicle_dir),
  priv_can_config_path: "can/bridges/#{bridge_firmware_id}.yml"
