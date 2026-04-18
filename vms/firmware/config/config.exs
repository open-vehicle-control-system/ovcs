# Compile-time configuration for the VMS firmware.
#
# Parameterised by one env var:
#   VEHICLE — top-level module name of the vehicle package (e.g. "Ovcs1").
#
# Runtime resolution of the VMS composer happens in `runtime.exs` so we
# can dereference the vehicle module after `Code.prepend_path`.
import Config

Application.start(:nerves_bootstrap)

# The blocks below configure Nerves-only apps (`:nerves`, `:nerves_ssh`,
# `:vintage_net`, `:mdns_lite`, `:shoehorn`, plus `:logger` with
# RingLogger as primary). On host they aren't in the dep tree and Mix
# would warn for each at boot, so gate them behind the target.
if Mix.target() != :host do
  config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
  config :nerves, source_date_epoch: "1708002919"
end

# Host-target mix commands (deps.get, test, compile) don't need a pinned
# vehicle — runtime.exs short-circuits the vehicle-specific block when
# config_env() == :test, and the stub below is never acted on at :host.
# Firmware cross-compile (Mix.target() != :host) still enforces.
vehicle_name =
  System.get_env("VEHICLE") ||
    if Mix.target() == :host do
      "Ovcs1"
    else
      Mix.raise("""
      VEHICLE env var is required for VMS firmware builds.

      Set it to the vehicle package's top-level module name, e.g.:
        VEHICLE=Ovcs1 mix firmware
      """)
    end

vehicle_dir = Macro.underscore(vehicle_name)
target = Mix.target() |> to_string()

# Firmware config files (fwup.conf, config.txt, ...) are served from
# `vms/firmware/targets/<mix-target>/` by default — every vehicle using a
# given Nerves target shares the same firmware recipe. A vehicle only ships
# its own file when it needs to override (e.g. a different CAN transceiver
# on the same SoC). Per-file fallback: vehicle's priv/firmware/vms/<file>
# wins when present, otherwise the shared target copy is used.
vehicle_override_rel = "../../vehicles/#{vehicle_dir}/priv/firmware/vms"
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

# Handoff to runtime.exs — runtime.exs picks this up to resolve the
# composer and wire :vms_core + :cantastic.
config :vms_firmware, vehicle: vehicle_name

# Cantastic: on firmware it owns CAN interface setup; on host the CLI
# (`ensure_host_can`) provisions vcan interfaces and rootless
# containers can't `ip link` anyway.
config :cantastic,
  setup_can_interfaces: Mix.target() != :host,
  otp_app: String.to_atom(vehicle_dir),
  enable_socketcand: Mix.target() != :host,
  socketcand_ip_interface: "eth0"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
