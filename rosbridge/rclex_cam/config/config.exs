import Config

config :rclex,
  ros2_message_types: [
    "sensor_msgs/msg/Image", "std_msgs/msg/Header"
  ]

config :rclex_cam,
  cameras: [
    %{
      process_name: TestCamera,
      device: 0,
      topic: "test_camera",
      props: %{width: 640, height: 480, fps: 30, buffersize: 2}
    }
  ]
