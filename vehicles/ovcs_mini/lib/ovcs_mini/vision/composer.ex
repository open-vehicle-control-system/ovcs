defmodule OvcsMini.Vision.Composer do
  @moduledoc """
  The OVCS Mini's vision unit: a Raspberry Pi 5 with two Camera Module 3
  (IMX708) on its CSI ports, the right one synchronised to the left by
  libcamera's software sync, depth on the CPU, and detection on a
  Hailo-8.

  The cameras bin the whole sensor (2304x1296) and deliver 480x270 grey
  frames, which the pipeline matches at that size. Every stage runs
  natively in `stereo_match` (`compute: :native`).

  On a workstation, `OVCS_SIM=1` reads the simulator's camera topics
  and stamps with its clock; without it, the unit runs no cameras.

  The detection model is fetched, not committed: `mise run fetch-models`
  at the repository root.
  """
  @behaviour VisionCore.Composer

  alias VisionCore.Stereo.Pipeline

  @hailo_model "priv/models/nanodet_repvgg.hef"

  @impl VisionCore.Composer
  def config(:host) do
    if System.get_env("OVCS_SIM") in ["1", "true"],
      do: simulation_config(),
      else: %VisionCore.Config{
        ros2: [zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1")],
        exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
      }
  end

  def config(:target) do
    %VisionCore.Config{
      ros2: [
        zenoh_endpoint_ip: Application.get_env(:vision_core, :zenoh_endpoint_ip, "127.0.0.1")
      ],
      components: [stereo_component(), hailo_detector()],
      exporters: [
        {VisionCore.Ros2.Exporter, heartbeat: [], stereo: [], detections: []},
        {VisionCore.Debug.Exporter, []}
      ]
    }
  end

  @impl VisionCore.Composer
  def required_files do
    ["priv/calibration/stereo_left.yaml", "priv/calibration/stereo_right.yaml", @hailo_model]
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
        {VisionCore.Ros2.Exporter, heartbeat: [], stereo: [publish_raw_images: false]}
      ]
    }
  end

  defp stereo_component do
    {:stereo,
     [
       driver: VisionCore.Camera.LibCamera,
       width: 480,
       height: 270,
       fps: 30,
       pair_tolerance_ms: 5,
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

  defp stages,
    do: Pipeline.default_stages(disparity: [num_disparities: 64, paths: 3, uniqueness: 1.2])

  defp hailo_detector do
    {:hailo_detector,
     hef_path: Application.app_dir(:ovcs_mini, @hailo_model), score_threshold: 0.4}
  end
end
