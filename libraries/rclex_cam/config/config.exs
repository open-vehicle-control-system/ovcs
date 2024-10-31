import Config

config :rclex,
  ros2_message_types: [
    "std_msgs/msg/Header",
    "sensor_msgs/msg/Image",
    "sensor_msgs/msg/CompressedImage",
    "sensor_msgs/msg/CameraInfo",
    "geometry_msgs/msg/Twist",
  ]

config :rclex_cam,
  cameras: [
    %{
      process_name: TestCamera,
      device: 0,
      topic: "test_camera",
      props: %{width: 640, height: 480, fps: 30, buffersize: 2},
      info: %{
        camera_matrix: [438.783367, 0.000000, 305.593336, 0.000000, 437.302876, 243.738352, 0.000000, 0.000000, 1.000000],
        distortion_model: "plumb_bob",
        distortion_coefficients: [-0.361976, 0.110510, 0.001014, 0.000505, 0.000000],
        rectification_matrix: [0.999978, 0.002789, -0.006046, -0.002816, 0.999986, -0.004401, 0.006034, 0.004417, 0.999972],
        projection_matrix: [393.653800, 0.000000, 322.797939, 0.000000, 0.000000, 393.653800, 241.090902, 0.000000, 0.000000, 0.000000, 1.000000, 0.000000]
      }
    }
  ]
