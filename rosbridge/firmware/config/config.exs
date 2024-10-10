# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :rclex,
  ros2_message_types: [
    "sensor_msgs/msg/Image", "sensor_msgs/msg/CompressedImage", "std_msgs/msg/Header"
  ]

config :rclex_cam,
  cameras: [
    %{
      process_name: FrontLeftCamera,
      device: 0,
      topic: "front_left_camera",
      frame_id: "camera1",
      props: %{width: 1280, height: 720, fps: 30}
    },
    %{
      process_name: FrontRightCamera,
      device: 2,
      topic: "front_right_camera",
      frame_id: "camera2",
      props: %{width: 1280, height: 720, fps: 30}
    }
  ]

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
