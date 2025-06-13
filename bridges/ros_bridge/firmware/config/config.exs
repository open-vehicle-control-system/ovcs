# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

vehicle      = (System.get_env("VEHICLE") || "OVCS1")
vehicle_path = Macro.underscore(vehicle)
vehicle_host = "#{vehicle_path |> String.replace("_", "-")}-ros-bridge"

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, :firmware, fwup_conf: "config/fwup.conf"

config :nerves, source_date_epoch: "1726737919"

config :ros_bridge_firmware, target: Mix.target()
config :ros_bridge_firmware, zenoh_endpoint_ip: "172.16.0.63"

config :cantastic,
  can_network_mappings: [{"ovcs", "vcan0"}],
  setup_can_interfaces: false,
  otp_app: :ros_bridge_firmware,
  priv_can_config_path: "ovcs_can.yml"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
