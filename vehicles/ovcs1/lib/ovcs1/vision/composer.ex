defmodule Ovcs1.Vision.Composer do
  @moduledoc """
  OVCS1's vision unit: an Arduino VENTUNO Q with two Raspberry Pi Global
  Shutter Cameras (IMX296) on Camera 0 (left) and Camera 1 (right), 20 cm
  apart with 6 mm lenses, captured over raw V4L2 through the board's CAMSS
  with the right sensor phase-locked to the left, depth computed on the
  GPU, and objects detected by YOLOX on the Hexagon NPU.

  `priv/firmware/vision/rootfs_overlay/boot/cameras.cfg` names the sensor on
  each of the board's connectors. The cameras deliver 728x544, half the
  sensor in each axis, and the pipeline matches at that size over 128
  disparities, coarse to fine.

  `priv/calibration` holds a nominal calibration (focal length from the
  lens and pixel pitch, no distortion, the 20 cm baseline) until the rig
  is calibrated.

  The GPU modules are compiled on a host into `priv/nx_iree_cache`, for
  the stages, their options and the matching size; rebuild it after
  changing any of them:

      mix vision_core.nx_cache --composer Ovcs1.Vision.Composer --out priv/nx_iree_cache

  The detection model, YOLOX w8a8 for QNN, is fetched, not committed:
  `mise run fetch-models` at the repository root. The board generates its
  context binary on first boot, into `/data/vision/qnn`.
  """

  @behaviour VisionCore.Composer

  alias VisionCore.Stereo.{NxSegment, Pipeline}

  @dlc "priv/models/yolox_w8a8.dlc"

  @impl VisionCore.Composer
  def config(:host) do
    %VisionCore.Config{
      ros2: [zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1")],
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    }
  end

  def config(:target) do
    %VisionCore.Config{
      ros2: [
        zenoh_endpoint_ip: Application.get_env(:vision_core, :zenoh_endpoint_ip, "127.0.0.1")
      ],
      components: [
        stereo_component(),
        {:qnn_detector, dlc_path: Application.app_dir(:ovcs1, @dlc), score_threshold: 0.4}
      ],
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: [], stereo: [], detections: []}]
    }
  end

  @impl VisionCore.Composer
  def required_files do
    [
      "priv/nx_iree_cache",
      "priv/calibration/stereo_left.yaml",
      "priv/calibration/stereo_right.yaml",
      @dlc
    ]
  end

  defp stereo_component do
    {:stereo,
     [
       driver: VisionCore.Camera.V4L2,
       width: 728,
       height: 544,
       fps: 30,
       match_width: 728,
       match_height: 544,
       # The Port pairs frames whose starts are within 1 ms.
       pair_tolerance_ms: 5,
       calibration_dir: Application.app_dir(:ovcs1, "priv/calibration"),
       calibration_store_dir: "/data/vision/calibration",
       stages:
         Pipeline.default_stages(disparity: [num_disparities: 128, search: "coarse_to_fine"]),
       defn_options: NxSegment.ventuno_q_defn_options({:ovcs1, "priv/nx_iree_cache"}),
       left: [
         frame_id: "stereo_left_optical",
         left_csiphy: 0,
         right_csiphy: 1,
         # The IMX296's black level, in 10-bit samples.
         black_level: 60
       ],
       right: [frame_id: "stereo_right_optical"]
     ]}
  end
end
