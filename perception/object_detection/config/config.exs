import Config
config :nx, :default_backend, EXLA.Backend

config :rclex,
  ros2_message_types: [
    "std_msgs/msg/Header",
    "sensor_msgs/msg/CompressedImage",
  ]

config :object_detection,
  config: %{
    input_image_topic: "/front_left_camera_compressed",
    output_lane_topic: "/object_detection/objects",
    node_name: "lane_estimation"
  }
