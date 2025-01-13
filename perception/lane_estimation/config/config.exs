import Config
config :nx, :default_backend, EXLA.Backend

config :rclex,
  ros2_message_types: [
    "std_msgs/msg/Header",
    "sensor_msgs/msg/CompressedImage",
  ]

config :lane_estimation,
  config: %{
    input_image_topic: "/front_left_camera_compressed",
    output_lane_topic: "/lane_detection/lane",
    node_name: "lane_estimation"
  }
