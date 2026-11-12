defmodule Ovcs1.Vision.Composer do
  @moduledoc """
  OVCS1's vision unit: an Arduino VENTUNO Q with two Raspberry Pi Global
  Shutter Cameras (IMX296) on Camera 0 (left) and Camera 1 (right), 20 cm
  apart with 6 mm lenses, captured over raw V4L2 through the board's CAMSS
  with the right sensor phase-locked to the left, depth computed on the
  GPU. A Raspberry Pi HQ Camera (IMX477) with a 3.6 mm lens on Camera 2
  is a camera of its own, `:center`, captured in colour by
  `VisionCore.Camera.V4L2Single`, at every frame in three outputs:
  `:view`, 2028 × 1520, made only for the two others and not sent to the
  vision core, where nothing takes it; `:view_jpeg`, that image encoded
  once by the capture program, which the dashboard's preview and the
  ROS 2 exporter both show as it is; and `:inference`, 1014 × 760,
  averaged from it 2 × 2. On the Hexagon NPU,
  YOLOX detects objects on `:inference`, the `:objects` pipeline, and
  FFNet segments the scene on it, the `:scene` pipeline, its road and
  off-road points among what it publishes: the models' inputs
  are smaller still, so the full image would cross to their Ports only
  to be shrunk there. Both take their distances from the stereo depth
  projected into the camera.

  `priv/firmware/vision/rootfs_overlay/boot/cameras.cfg` names the sensor on
  each of the board's connectors. The stereo cameras deliver 728x544, half
  the sensor in each axis, and the pipeline matches at that size over 128
  disparities, coarse to fine.

  `priv/calibration` holds the rig's calibration, from `cameracalibrator`,
  and the center camera's nominal one, `center.yaml`, for its 3.6 mm lens,
  until it is calibrated. Without `center_pose.yaml`, its pose relative
  to the stereo pair, its pipelines run without distances. The stereo
  cameras deliver grey frames, which the ROS 2 exporter encodes to JPEG;
  it publishes every pair (`raw_image_max_hz` at the capture rate), so a
  consumer pairing left and right images gets frames of the same capture.

  The GPU modules are compiled on a host into `priv/nx_iree_cache`, for
  the stages, their options and the matching size; rebuild it after
  changing any of them:

      mix vision_core.nx_cache --composer Ovcs1.Vision.Composer --out priv/nx_iree_cache

  The models, YOLOX and FFNet-122NS-LowRes w8a8 for QNN, are fetched, not
  committed: `mise run fetch-models` at the repository root. FFNet's
  weights are for non-commercial use only. The board generates each
  model's context binary on first boot, into `/data/vision/qnn/<pipeline>`.
  """

  @behaviour VisionCore.Composer

  alias VisionCore.Stereo.{NxSegment, Pipeline}

  @detection_model "priv/models/yolox_w8a8.dlc"
  @segmentation_model "priv/models/ffnet_122ns_lowres.dlc"
  @center_calibration "priv/calibration/center.yaml"
  @center_pose "priv/calibration/center_pose.yaml"
  @calibration_store_dir "/data/vision/calibration"

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
        center_camera(),
        {:qnn_detector,
         name: :objects,
         source: {:camera, :center, :inference},
         dlc_path: Application.app_dir(:ovcs1, @detection_model),
         score_threshold: 0.4},
        {:qnn_segmenter,
         name: :scene,
         source: {:camera, :center, :inference},
         dlc_path: Application.app_dir(:ovcs1, @segmentation_model),
         segment_every_n: 1}
      ],
      preview: [max_hz: 30, outputs: [center: :view_jpeg]],
      exporters: [
        {VisionCore.Ros2.Exporter,
         heartbeat: [],
         stereo: [raw_image_max_hz: 30],
         detections: [pipelines: [:objects]],
         cameras: [names: [:center], outputs: [center: :view_jpeg]],
         segmentation: [pipelines: [:scene]]}
      ]
    }
  end

  @impl VisionCore.Composer
  def required_files do
    [
      "priv/nx_iree_cache",
      "priv/calibration/stereo_left.yaml",
      "priv/calibration/stereo_right.yaml",
      @center_calibration,
      @detection_model,
      @segmentation_model
    ]
  end

  defp center_camera do
    {:camera,
     name: :center,
     driver: VisionCore.Camera.V4L2Single,
     csiphy: 2,
     fps: 30,
     outputs: [
       view: [resolution: {2028, 1520}, processor: :cpu, send: false],
       view_jpeg: [from: :view, format: :jpeg, quality: 80],
       inference: [resolution: {1014, 760}, from: :view]
     ],
     max_exposure_us: 25_000,
     frame_id: "center_optical",
     calibration: Application.app_dir(:ovcs1, @center_calibration),
     pose: Application.app_dir(:ovcs1, @center_pose),
     calibration_store_dir: @calibration_store_dir}
  end

  defp stereo_component do
    {:stereo,
     [
       driver: VisionCore.Camera.V4L2Pair,
       width: 728,
       height: 544,
       fps: 30,
       # The IMX296's black level, in 10-bit samples.
       black_level: 60,
       match_width: 728,
       match_height: 544,
       # The Port pairs frames whose starts are within 1 ms.
       pair_tolerance_ms: 5,
       calibration_dir: Application.app_dir(:ovcs1, "priv/calibration"),
       calibration_store_dir: @calibration_store_dir,
       stages:
         Pipeline.default_stages(
           disparity: [num_disparities: 128, search: "coarse_to_fine", coarse_paths: 3]
         ),
       defn_options: NxSegment.ventuno_q_defn_options({:ovcs1, "priv/nx_iree_cache"}),
       left: [frame_id: "stereo_left_optical", csiphy: 0],
       right: [frame_id: "stereo_right_optical", csiphy: 1]
     ]}
  end
end
