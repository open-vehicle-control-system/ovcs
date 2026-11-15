defmodule OvcsMini.Vision.Composer do
  @moduledoc """
  The OVCS Mini's vision unit: a Raspberry Pi 5 with two Camera Module 3
  (IMX708) on its CSI ports, the right one synchronised to the left by
  libcamera's software sync, depth on the CPU, and detection and scene
  segmentation on a Hailo-8.

  The cameras bin the whole sensor (2304x1296) and deliver 480x270 grey
  frames, 25 a second, which the pipeline matches at that size, at most
  20 pairs a second (`max_hz`). Every stage runs natively in
  `stereo_match` (`compute: :native`). At 30 frames a second the Pi 5's
  memory bandwidth no longer keeps up with the cameras, the depth, the
  Hailo-8's transfers and the ROS 2 exporter together.

  The left camera's capture also makes a colour camera of its own,
  `:left` (`VisionCore.Camera.LibCameraStream`): a second ISP stream at
  half the sensor mode, sent as a JPEG on each frame (`max_hz`). The
  stereo frames do not change.

  Detection and the scene's segmentation, `:scene`, both run on that
  colour image, on the Hailo-8 (`VisionCore.Hailo`), on one frame in
  three: NanoDet finds the objects, DDRNet-23-slim classes each part of
  the image among the Cityscapes classes. More often, the Pi 5's memory
  bandwidth no longer keeps up with the depth beside them. Both take their
  distances from the stereo depth projected into the camera, once it is
  calibrated and its pose measured.

  The ROS 2 exporter publishes the rectified pair, which the cockpit
  shows, and the left camera's JPEG. The bag exporter records the
  unit's ROS 2 messages on its disks, started and stopped from the
  dashboard's ROS 2 · Bag page or `/api/recordings`.

  On a workstation, `OVCS_SIM=1` reads the simulator's camera topics
  and stamps with its clock; without it, the unit runs no cameras.

  The detection model is fetched, not committed: `mise run fetch-models`
  at the repository root. The segmentation model is compiled for the
  Mini's band, `models/README.md`.
  """
  @behaviour VisionCore.Composer

  alias VisionCore.Stereo.Pipeline

  @hailo_model "priv/models/nanodet_repvgg.hef"
  @segmentation_model "priv/models/ddrnet_23_slim_576x1152.hef"

  @impl VisionCore.Composer
  def config(:host) do
    if System.get_env("OVCS_SIM") in ["1", "true"],
      do: simulation_config(),
      else: %VisionCore.Config{
        ros2: [zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1")],
        exporters: [{VisionCore.Ros2.ZenohExporter, heartbeat: []}]
      }
  end

  def config(:target) do
    %VisionCore.Config{
      ros2: [
        zenoh_endpoint_ip: Application.get_env(:vision_core, :zenoh_endpoint_ip, "127.0.0.1")
      ],
      components: [stereo_component(), colour_camera(), hailo_detector(), hailo_segmenter()],
      exporters: [
        {VisionCore.Ros2.ZenohExporter,
         heartbeat: [],
         stereo: [publish_rectified_image: true],
         cameras: [names: [:left], outputs: [left: :half_jpeg]],
         detections: [],
         segmentation: [pipelines: [:scene]]},
        {VisionCore.Snapshot.Exporter, []},
        {VisionCore.Ros2.BagExporter, []}
      ]
    }
  end

  @impl VisionCore.Composer
  def required_files do
    [
      "priv/calibration/stereo_left.yaml",
      "priv/calibration/stereo_right.yaml",
      @hailo_model,
      @segmentation_model
    ]
  end

  # Gazebo renders an ideal pinhole, so the simulator has a calibration of its own.
  defp simulation_config do
    %VisionCore.Config{
      ros2: [
        zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
        simulator_clock: true
      ],
      components: [
        {:stereo,
         driver: VisionCore.Ros2.Camera,
         width: 480,
         height: 270,
         calibration_dir: Application.app_dir(:ovcs_mini, "priv/calibration/simulation"),
         stages: stages(),
         compute: :native,
         left: [frame_id: "stereo_left_optical", topic: "/stereo/left/image_raw/compressed"],
         right: [frame_id: "stereo_right_optical", topic: "/stereo/right/image_raw/compressed"]}
      ],
      exporters: [
        {VisionCore.Ros2.ZenohExporter,
         heartbeat: [], stereo: [publish_raw_images: false, publish_rectified_image: true]}
      ]
    }
  end

  defp stereo_component do
    {:stereo,
     [
       driver: VisionCore.Camera.LibCamera,
       width: 480,
       height: 270,
       fps: 25,
       pair_tolerance_ms: 5,
       max_hz: 20,
       calibration_dir: Application.app_dir(:ovcs_mini, "priv/calibration"),
       calibration_store_dir: "/data/vision/calibration",
       stages: stages(),
       compute: :native,
       # libcamera's camera 0 is the right module on this bar.
       left: [frame_id: "stereo_left_optical", camera_id: 1, sync: :server] ++ camera_options(),
       right: [frame_id: "stereo_right_optical", camera_id: 0, sync: :client] ++ camera_options()
     ]}
  end

  # The calibration holds for this sensor mode and lens position only.
  defp camera_options,
    do: [exposure_mode: :short, lens_position: 1.0, sensor_mode: {2304, 1296}, format: :grey]

  defp stages do
    Pipeline.default_stages(
      disparity: [num_disparities: 64, paths: 3, p1: 24, p2: 79, uniqueness: 1.1],
      speckle_filter: [min_support: 24]
    )
  end

  defp colour_camera do
    {:camera,
     name: :left,
     driver: VisionCore.Camera.LibCameraStream,
     stream_of: :left,
     max_hz: 25,
     outputs: [
       half: [resolution: {1152, 648}, processor: :isp, send: false],
       half_jpeg: [from: :half, format: :jpeg, quality: 80]
     ],
     calibration_store_dir: "/data/vision/calibration"}
  end

  defp hailo_detector do
    {:hailo_detector,
     source: {:camera, :left, :half_jpeg},
     hef_path: Application.app_dir(:ovcs_mini, @hailo_model),
     score_threshold: 0.4,
     detect_every_n: 3}
  end

  defp hailo_segmenter do
    {:hailo_segmenter,
     name: :scene,
     source: {:camera, :left, :half_jpeg},
     hef_path: Application.app_dir(:ovcs_mini, @segmentation_model),
     segment_every_n: 3}
  end
end
