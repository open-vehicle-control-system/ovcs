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
    "std_msgs/msg/Header",
    "sensor_msgs/msg/Image",
    "sensor_msgs/msg/CompressedImage",
    "sensor_msgs/msg/CameraInfo",
    "geometry_msgs/msg/Twist",
  ]

config :ros_bridge_firmware,
  vehicle: vehicle,
  vehicle_host: vehicle_host,
  cameras: [
    %{
      process_name: FrontLeftCamera,
      device: 0,
      topic: "front_left_camera",
      frame_id: "camera1",
      props: %{width: 640, height: 480, fps: 5},
      info: %{
        camera_matrix: [438.783367, 0.000000, 305.593336, 0.000000, 437.302876, 243.738352, 0.000000, 0.000000, 1.000000],
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.361976, 0.110510, 0.001014, 0.000505, 0.000000],
        rectification_matrix: [0.999978, 0.002789, -0.006046, -0.002816, 0.999986, -0.004401, 0.006034, 0.004417, 0.999972],
        projection_matrix: [393.653800, 0.000000, 322.797939, 0.000000, 0.000000, 393.653800, 241.090902, 0.000000, 0.000000, 0.000000, 1.000000, 0.000000]
      }
    },
    #%{
    #  process_name: FrontRightCamera,
    #  device: 2,
    #  topic: "front_right_camera",
    #  frame_id: "camera2",
    #  props: %{width: 640, height: 480, fps: 30}
    #}
  ],
  orchestrator: ROSBridgeFirmware.NetworkWatcher

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1726737919"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
