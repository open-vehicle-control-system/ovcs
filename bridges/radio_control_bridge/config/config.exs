# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, :firmware, fwup_conf: "config/fwup.conf"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1729155399"

config :cantastic,
  can_network_mappings: [{"ovcs", "vcan0"}],
  setup_can_interfaces: false,
  otp_app: :radio_control_bridge,
  priv_can_config_path: "ovcs_can.yml"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
