import Config

config :rclex,
  ros2_message_types: [
    "sensor_msgs/msg/Image", "std_msgs/msg/Header"
  ]

config :cv_bridgex,
  cameras: [
    %{
      process_name: TestCamera,
      emitter_process_name: TestCameraEmitter,
      device_id: 0,
      topic: "test_camera",
      capture_backend: :opencv
    }
  ]
