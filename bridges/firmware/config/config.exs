# Compile-time configuration for the shared bridge firmware.
#
# The firmware is parameterised by two env vars (set by the CLI or by
# hand):
#   VEHICLE              — e.g. "Ovcs1"
#   BRIDGE_FIRMWARE_ID   — key into the vehicle's bridge_firmwares/0
#                          (e.g. "radio_control", "autonomy")
#
# Runtime resolution of which bridges to supervise happens in
# `BridgeFirmware.Resolver` so the config here can stay static.
import Config

Application.start(:nerves_bootstrap)

config :firmware, target: Mix.target()

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, source_date_epoch: "1729155399"

vehicle_name =
  System.get_env("VEHICLE") ||
    Mix.raise("""
    VEHICLE env var is required for bridge firmware builds.
    Set it to the vehicle package's top-level module name, e.g.:
      VEHICLE=Ovcs1 BRIDGE_FIRMWARE_ID=radio_control mix firmware
    """)

bridge_firmware_id =
  System.get_env("BRIDGE_FIRMWARE_ID") ||
    Mix.raise("""
    BRIDGE_FIRMWARE_ID env var is required for bridge firmware builds.
    Set it to a key from the vehicle's bridge_firmwares/0 map.
    """)

vehicle_dir = Macro.underscore(vehicle_name)
target = Mix.target() |> to_string()

# Same per-file fallback as vms/firmware: a vehicle override at
# vehicles/<vehicle>/priv/firmware/bridges/<id>/<file> wins over the
# shared default at bridges/firmware/targets/<target>/<file>.
# Relative paths must be used for `fwup_conf` (Nerves concatenates
# absolute paths to the app dir).
vehicle_override_rel =
  "../../vehicles/#{vehicle_dir}/priv/firmware/bridges/#{bridge_firmware_id}"

target_default_rel = "targets/#{target}"

vehicle_override_abs = Path.expand("../#{vehicle_override_rel}", __DIR__)
target_default_abs = Path.expand("../#{target_default_rel}", __DIR__)

resolve_firmware_file = fn file ->
  if File.exists?(Path.join(vehicle_override_abs, file)),
    do: Path.join(vehicle_override_rel, file),
    else: Path.join(target_default_rel, file)
end

vehicle_firmware_dir =
  if File.exists?(Path.join(vehicle_override_abs, "config.txt")),
    do: vehicle_override_abs,
    else: target_default_abs

System.put_env("VEHICLE_FIRMWARE_DIR", vehicle_firmware_dir)

config :nerves, :firmware, fwup_conf: resolve_firmware_file.("fwup.conf")

# Handoff to runtime.exs via env — avoids compile-time coupling on
# the vehicle module's bridge_firmwares/0.
config :bridge_firmware,
  vehicle: vehicle_name,
  bridge_firmware_id: bridge_firmware_id

# CAN: the vehicle ships the per-firmware YAML at
# priv/can/bridges/<id>.yml unless its bridge_firmwares/0 entry
# overrides :can_config_path. Resolution happens in runtime.exs so
# we can read the vehicle module.
config :cantastic,
  setup_can_interfaces: true,
  otp_app: String.to_atom(vehicle_dir),
  enable_socketcand: false

vehicle_host =
  "#{vehicle_dir |> String.replace("_", "-")}-bridge-#{bridge_firmware_id |> String.replace("_", "-")}"

config :logger, backends: [RingLogger]
config :shoehorn, init: [:nerves_runtime, :nerves_pack]
config :nerves, :erlinit, update_clock: true, hostname_pattern: vehicle_host

config :nerves_ssh,
  authorized_keys:
    (System.get_env("AUTHORIZED_SSH_KEYS") || "") |> String.split(",", trim: true)

config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}
  ]

config :mdns_lite,
  hosts: [:hostname, vehicle_host],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
