import Config

config :rclex,
  ros2_message_types: [
    "sensor_msgs/msg/Image", "std_msgs/msg/Header"
  ]

  config :cv_bridgex,
    cameras: [
      %{
        process_name: FrontLeftCamera,
        device_id: 0,
        topic: "/front_left_camera"
      },
      %{
        process_name: FrontRightCamera,
        device_id: 2,
        topic: "/front_right_camera"
      }
    ]
