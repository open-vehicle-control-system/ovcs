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

config :rclex,
  ros2_message_types: [
    "std_msgs/msg/String",
    "sensor_msgs/msg/Joy",
    "geometry_msgs/msg/Twist",
    "sensor_msgs/msg/Imu"
  ]

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, :firmware, fwup_conf: "config/fwup.conf"

config :nerves, source_date_epoch: "1726737919"

config :ros_bridge_firmware, target: Mix.target()
config :ros_bridge_firmware, zenoh_endpoint_ip: "172.16.0.63"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
