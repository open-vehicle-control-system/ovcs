# Compile-time configuration for the vision firmware.
#
# Parameterised by one env var:
#   VEHICLE — top-level module name of the vehicle package.
#
# The vision composer is resolved in `runtime.exs`, after the vehicle's
# ebin is on the code path.
import Config

Application.start(:nerves_bootstrap)

# Nerves-only apps are not in the host dep tree.
if Mix.target() != :host do
  config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
  config :nerves, source_date_epoch: "1761523200"
end

# Host-target mix commands (deps.get, test, compile) run without a
# vehicle; a host BEAM started without one stops in config/runtime.exs.
# Firmware builds require one here.
vehicle_name =
  System.get_env("VEHICLE") ||
    if Mix.target() != :host do
      Mix.raise("""
      VEHICLE env var is required for vision firmware builds.

      Set it to the vehicle package's top-level module name, e.g.:
        VEHICLE=<Vehicle> mix firmware
      """)
    end

vehicle_directory = vehicle_name && Macro.underscore(vehicle_name)
target = Mix.target() |> to_string()

# Per-file fallback, as in vms/firmware: a vehicle's
# priv/firmware/vision/<file> wins over targets/<mix-target>/<file>.
# `fwup_conf` must be relative (Nerves joins it to the app dir).
vehicle_override_relative = "../../vehicles/#{vehicle_directory}/priv/firmware/vision"
target_default_relative = "targets/#{target}"

vehicle_override_absolute = Path.expand("../#{vehicle_override_relative}", __DIR__)
target_default_absolute = Path.expand("../#{target_default_relative}", __DIR__)

resolve_firmware_file = fn file ->
  if File.exists?(Path.join(vehicle_override_absolute, file)),
    do: Path.join(vehicle_override_relative, file),
    else: Path.join(target_default_relative, file)
end

# The boot files are taken as a set: a vehicle overriding config.txt
# ships cmdline-a.txt and cmdline-b.txt too.
vehicle_firmware_directory =
  if File.exists?(Path.join(vehicle_override_absolute, "config.txt")),
    do: vehicle_override_absolute,
    else: target_default_absolute

System.put_env("VEHICLE_FIRMWARE_DIR", vehicle_firmware_directory)

fwup_conf = resolve_firmware_file.("fwup.conf")

# A target without a fwup.conf of its own, such as okdo_c100, uses its system's.
if File.exists?(Path.expand("../#{fwup_conf}", __DIR__)) do
  config :nerves, :firmware, fwup_conf: fwup_conf
end

config :vision_firmware, vehicle: vehicle_name

# vision_api serves JSON:API; path deps' config is not loaded here.
config :mime, :types, %{"application/vnd.api+json" => ["jsonapi"]}

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
