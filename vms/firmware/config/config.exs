# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :firmware, target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1708002919"

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
       VEHICLE env var is required for VMS firmware builds.

       Set it to the vehicle package's top-level module name, e.g.:
         VEHICLE=Ovcs1 mix firmware
       """)
     end)

vehicle_dir = Macro.underscore(vehicle_name)
target = Mix.target() |> to_string()

# Firmware config files (fwup.conf, config.txt, ...) are served from
# `vms/firmware/targets/<mix-target>/` by default — every vehicle using a
# given Nerves target shares the same firmware recipe. A vehicle only ships
# its own file when it needs to override (e.g. a different CAN transceiver
# on the same SoC). Per-file fallback: vehicle's priv/firmware/vms/<file>
# wins when present, otherwise the shared target copy is used.
# Nerves' `fwup_conf` must be a path relative to the firmware app
# (vms/firmware/), otherwise it gets concatenated to the project dir.
# Keep both candidate paths relative; `VEHICLE_FIRMWARE_DIR` is set
# absolute because fwup.conf's `host-path` values aren't rebased.
vehicle_override_rel = "../../vehicles/#{vehicle_dir}/priv/firmware/vms"
target_default_rel = "targets/#{target}"

vehicle_override_abs = Path.expand("../#{vehicle_override_rel}", __DIR__)
target_default_abs = Path.expand("../#{target_default_rel}", __DIR__)

resolve_firmware_file = fn file ->
  if File.exists?(Path.join(vehicle_override_abs, file)),
    do: Path.join(vehicle_override_rel, file),
    else: Path.join(target_default_rel, file)
end

# fwup.conf references siblings (config.txt etc.) via ${VEHICLE_FIRMWARE_DIR};
# stash the absolute path so fwup can resolve host-path values.
vehicle_firmware_dir =
  if File.exists?(Path.join(vehicle_override_abs, "config.txt")),
    do: vehicle_override_abs,
    else: target_default_abs

System.put_env("VEHICLE_FIRMWARE_DIR", vehicle_firmware_dir)

config :nerves, :firmware, fwup_conf: resolve_firmware_file.("fwup.conf")

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
