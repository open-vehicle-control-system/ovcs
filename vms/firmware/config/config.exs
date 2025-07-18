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

# Change fwup.conf path if needed
config :nerves, :firmware,
  fwup_conf: "config/default/fwup.conf"
#config :nerves, :firmware,
#  fwup_conf: "config/obd2_waveshare_2can_hat/fwup.conf"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
