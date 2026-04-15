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

vehicle_name =
  System.get_env("VEHICLE") ||
    Mix.raise("""
    VEHICLE env var is required for VMS firmware builds.

    Set it to the vehicle package's top-level module name, e.g.:
      VEHICLE=Ovcs1 mix firmware
    """)

vehicle_dir = Macro.underscore(vehicle_name)
vehicle_firmware_dir =
  Path.expand("../../../vehicles/#{vehicle_dir}/priv/firmware/vms", __DIR__)

# fwup.conf references siblings (config.txt etc.) via ${VEHICLE_FIRMWARE_DIR};
# stash the absolute path so fwup can resolve host-path values regardless of
# where Nerves runs it from.
System.put_env("VEHICLE_FIRMWARE_DIR", vehicle_firmware_dir)

config :nerves, :firmware,
  fwup_conf: "../../vehicles/#{vehicle_dir}/priv/firmware/vms/fwup.conf"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
