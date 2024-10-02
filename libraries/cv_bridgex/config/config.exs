import Config

config :rclex,
  ros2_message_types: [
    "sensor_msgs/msg/Image", "std_msgs/msg/Header"
  ],
  ros2_service_types: [
    "std_srvs/srv/SetBool"
  ],
  ros2_action_types: [
    "turtlesim/action/RotateAbsolute"
  ]
