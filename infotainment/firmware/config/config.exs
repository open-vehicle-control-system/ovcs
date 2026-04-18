# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :infotainment_firmware, target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1698084254"

# Host-target mix commands (deps.get, test, compile) don't need a pinned
# vehicle — runtime.exs short-circuits the vehicle-specific block when
# config_env() == :test, and the stub below is never acted on at :host.
# Firmware cross-compile (Mix.target() != :host) still enforces.
vehicle_name =
  System.get_env("VEHICLE") ||
    (if Mix.target() == :host do
       "Ovcs1"
     else
       Mix.raise("""
       VEHICLE env var is required for infotainment firmware builds.

       Set it to the vehicle package's top-level module name, e.g.:
         VEHICLE=Ovcs1 mix firmware
       """)
     end)

vehicle_dir = Macro.underscore(vehicle_name)
target = Mix.target() |> to_string()

# Same per-file fallback as vms/firmware. Nerves' `fwup_conf` must be
# a path relative to the firmware app (infotainment/firmware/); keep
# both candidates relative and set VEHICLE_FIRMWARE_DIR absolute for
# fwup.conf's host-path values.
vehicle_override_rel = "../../vehicles/#{vehicle_dir}/priv/firmware/infotainment"
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

config :nerves, :erlinit,
  ctty: "tty3",
  warn_unused_tty: false

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
