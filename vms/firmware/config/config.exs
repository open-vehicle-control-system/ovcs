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

fwup_conf =
  case System.get_env("VEHICLE") do
    "OVCS1" -> "config/default/fwup.conf"
    "OBD2" -> "config/obd2_waveshare_2can_hat/fwup.conf"
    vehicle ->
      Mix.raise("""
      Vehicle "#{vehicle}" is not supported by VMS firmware.

      Supported vehicles: OVCS1, OBD2

      Set the VEHICLE environment variable to a supported vehicle, e.g.:
        VEHICLE=OVCS1 mix firmware
      """)
  end

config :nerves, :firmware, fwup_conf: fwup_conf

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
