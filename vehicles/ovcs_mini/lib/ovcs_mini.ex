defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge

  @impl OvcsVehicle
  def name, do: "OVCS Mini"
  @impl OvcsVehicle
  def vms, do: OvcsMini.Vms.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl OvcsVehicle
  def vms_target, do: :ovcs_base_can_system_rpi4

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      },
      "ros" => %{
        target: :ovcs_base_can_system_rpi4,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      },
      # Perception bridge: stereo Pi cameras + Hailo inference on a
      # Pi 5 + Hailo hat. Uses upstream nerves_system_rpi5 (libcamera
      # and HailoRT are already in the system; see
      # bridges/firmware/mix.exs).
      # Perception bridge: no local CAN transceiver — it joins the
      # bus over Zenoh on a separate Pi. The target mapping still
      # has to satisfy Cantastic's "valid network" contract, so we
      # point it at a virtual CAN device. Cantastic auto-creates
      # vcan0 at boot (`ip link add dev vcan0 type vcan`), so this
      # is zero-config on the Pi 5; no SPI/MCP251xFD wait needed.
      "ros_perception" => %{
        target: :rpi5,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:vcan0"}
      }
    }
  end

  @impl RadioControlBridge
  def radio_control_bridge_config(:host),
    do: %RadioControlBridge.Config{components: []}

  def radio_control_bridge_config(:target),
    do: %RadioControlBridge.Config{
      components: [
        {:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}
        # MSP OSD path — declared but not enabled. Strip the leading
        # `# ` from the data line below and replace the UART with the
        # actual VTX serial line once `RadioControlBridge.MspOsdForwarder`
        # ships a real impl. (The leading comma is intentional so
        # enabling is a clean prefix removal — no other edits needed.)
        # , {:msp_osd_forwarder, uart_port: "ttyXXX", uart_baud_rate: 115_200}
      ]
    }

  @impl RosBridge
  def ros_bridge_config(:host, "ros_perception"),
    do: perception_host_config()

  def ros_bridge_config(:target, "ros_perception"),
    do: perception_target_config()

  def ros_bridge_config(:host, _firmware_id),
    do: ros_host_config()

  def ros_bridge_config(:target, _firmware_id),
    do: ros_target_config()

  # The Mini runs two ROS bridges on one Zenoh fabric (this one and
  # the perception Pi), so each names its ROS node explicitly —
  # otherwise both announce `ovcs_bridge` and the ROS graph cannot
  # tell them apart.
  defp ros_host_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: OvcsDrivers.Imu.Dummy}
      ]
    }

  defp ros_target_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: BNO085.I2C}
      ]
    }

  defp perception_host_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_perception",
      components: [
        :heartbeat,
        stereo_component(RosBridge.Camera.GStreamer, :host)
      ]
    }
  end

  defp perception_target_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      node_name: "ovcs_bridge_perception",
      components: [
        :heartbeat,
        stereo_transforms(),
        stereo_component(RosBridge.Camera.LibCamera, :target),
        # After :stereo_camera — the detector registers on that
        # unit's backend while starting.
        hailo_detector()
      ]
    }
  end

  # Where the stereo bar sits on the car. Without this, `stereo_left`
  # is a label nothing can resolve: a consumer knows a point is 1.2 m
  # in front of the camera but not where the camera is, so it cannot
  # express the measurement in the car's own terms — and Foxglove's 3D
  # panel reports the frame missing and draws nothing.
  #
  # The rotation is the standard body -> optical frame change, not a
  # mounting angle: base_link is REP-103 (x forward, y left, z up)
  # while an optical frame is x right, y down, z into the image. That
  # is what the (-0.5, 0.5, -0.5, 0.5) quaternion does.
  #
  # x is measured, z is not.
  #
  # `base_link` sits midway between the axles, so with a 324 mm
  # wheelbase the front axle is 162 mm ahead of it. The camera bar is
  # 120 mm behind the front axle, which puts the lenses at
  # 162 - 120 = 42 mm forward of base_link. The value here was 100 mm
  # — a guess that placed the cameras 58 mm too far forward and shifted
  # every detection on the vehicle by that much.
  #
  # y is 0: the bar straddles the centreline, and the pair's own 90 mm
  # baseline is carried by the calibration, not by this transform,
  # which locates `stereo_left` — the frame the depth image and
  # detections are published in.
  #
  # TODO: z is still the original guess. Measure the lens centre height
  # above the ground; it is the last unmeasured number in the vehicle's
  # geometry.
  defp stereo_transforms do
    {:static_transforms,
     transforms: [
       %{
         parent: "base_link",
         child: "stereo_left",
         translation: {0.042, 0.0, 0.12},
         rotation: {-0.5, 0.5, -0.5, 0.5}
       }
     ]}
  end

  # YOLO on the Hailo-8, fused with the stereo depth map. Target
  # only: the accelerator is a physical card on the perception Pi, and
  # on the host the component would start, fail to find /dev/hailo0,
  # and log an error every boot for no benefit.
  #
  # Costs the stereo path nothing worth reclaiming. Inference runs on
  # silicon that is otherwise idle at 3.3 ms a frame, and the input is
  # the rectified left image the backend already produced — no extra
  # decode, no extra rectify. The only shared work is a median over
  # each box.
  #
  # Grayscale in, deliberately: measured on the device against
  # ultralytics' bus.jpg, gray scored within 0.01 of colour
  # (person 0.881 vs 0.888), so the pipeline's existing gray frame is
  # worth exactly as much here as a colour one we would have to decode
  # separately.
  defp hailo_detector do
    {:hailo_detector,
     hef_path: Path.join(priv_models_dir(), "yolov8n.hef"),
     # 0.4 is where a yolov8n at this resolution stops reporting
     # furniture as animals. Measured at 480x270 the model still
     # scores real people at 0.74-0.91, so this leaves plenty of
     # headroom above the noise.
     score_threshold: 0.4,
     # The stereo unit's own frame, since boxes are positioned in its
     # rectified pixels.
     frame_id: "stereo_left"}
  end

  defp priv_models_dir, do: :ovcs_mini |> :code.priv_dir() |> Path.join("models")

  # Self-contained stereo perception block. Inherits most defaults
  # from `RosBridge.StereoCamera.Supervisor` (backend
  # `StereoCamera.OpenCV`, topic prefix `"stereo"`, frame_ids
  # `stereo_left` / `stereo_right`, calibration paths
  # `<calibration_dir>/stereo_<side>.yaml`). We override resolution
  # and SGBM parameters here to keep the disparity rate usable on a
  # laptop CPU (≈ 2 Hz at 640×480, vs ≈ 0.7 Hz at 1280×720).
  #
  # Host note: each USB camera must be on a *separate* USB
  # controller. uvcvideo reserves isochronous bandwidth on the
  # worst-case (uncompressed) basis, so two MJPEG streams on the
  # same USB 2 hub will fail with "Buffer pool activation failed".
  defp stereo_component(camera_driver, arm) do
    {:stereo_camera,
     driver: camera_driver,
     calibration_dir: priv_calibration_dir(),
     # 640×360 is 16:9 — the sensor's native aspect. Asking a 16:9
     # sensor for a 4:3 buffer squeezed the full field of view into
     # 480 rows, which showed up in the calibration as fy/fx = 1.334
     # (anamorphic pixels) and cost 1.44x on the near clip, because
     # rectification then inflates f from ~725 to 1046 restoring
     # square pixels. Native aspect also means 25 % fewer pixels for
     # SGBM, which scales with `width × height × num_disparities`.
     #
     # 480x270 keeps that 16:9 aspect and is a pure isotropic
     # downscale, which is why the 640x360 calibration still applies:
     # the backend scales K and P to the capture resolution, and for a
     # proportional resize that scaling is exact (distortion
     # coefficients are normalised). Changing the *aspect* is what
     # requires a fresh calibration, not changing the size.
     #
     # Resolution is the best lever this pipeline has, because it cuts
     # compute and improves near range at once: f scales with width,
     # and the near clip is (f x baseline) / num_disparities. Measured
     # offline on identical rectified frames, coverage held at ~38-39 %
     # across 640/560/480/400 wide — SGBM's limit here is texture, not
     # pixel count — while cost and near clip both fell:
     #
     #   640x360   f*B 69.7   clip 0.73 m   SGBM ~141 ms
     #   480x270   f*B 52.3   clip 0.55 m   SGBM  ~79 ms
     #
     # The price is depth precision at distance, since dZ = Z^2 dd /
     # (f*B): about 3.8 cm at 2 m against 2.9 cm at 640 wide. Fine for
     # deciding whether to stop for something; not fine for mapping.
     width: 480,
     height: 270,
     fps: 30,
     # Wide enough for the unsynchronized USB cameras on host;
     # drop to 5 ms once the perception target has FSIN-tied CSI
     # modules.
     pair_tolerance_ms: 100,
     # num_disparities sets the *near* clip: Z_min = (f × baseline) /
     # num_disparities. With the calibrated f·B of 93.9 px·m, 48
     # disparities clipped at 2.0 m — everything closer was clamped
     # there (measured: image centre pinned at exactly 2.00 m, 5 % of
     # valid pixels at the ceiling), which is useless on a car whose
     # obstacles live between 0.2 and 3 m. 96 brings the clip to
     # ~0.98 m. SGBM cost scales roughly linearly with this, so it is
     # bought with frame rate: 128 reached 0.74 m but pushed the Pi to
     # load 5.7 on 4 cores, dropped disparity to 3.6 Hz and starved
     # the capture path down to 26 Hz. It also blinds the leftmost
     # `num_disparities` columns, so 128 costs 20 % of the image width
     # against 15 % here. The real headroom is in capturing 16:9
     # instead of 4:3 — the anamorphic squeeze inflates rectified f
     # from 725 to 1046, and undoing it buys the same near clip for
     # ~1.44x fewer disparities. Must stay a multiple of 16.
     # block_size=7 is a balanced point between bs=5 (denser
     # coverage but jittery) and bs=9 (stable but sparse) — gives
     # ~30 % more frame-to-frame stability for ~5 pp coverage cost.
     # Speckle filtering, tuned against the measured failure mode
     # rather than the defaults: the map's problem is not missing
     # pixels but confident wrong ones — isolated blobs reading
     # 3.5 m inside a 2 m surface, from false matches on repetitive
     # structure like shelving. A hole is honest; a phantom obstacle
     # is not. Doubling the window and halving the tolerated internal
     # range invalidates those blobs; costs some coverage.
     backend_opts: [
       num_disparities: 96,
       block_size: 7,
       speckle_window_size: 200,
       speckle_range: 16
     ],
     left: camera_addressing(arm, :left),
     right: camera_addressing(arm, :right)}
  end

  defp camera_addressing(:host, :left), do: [device: "/dev/video2"]
  defp camera_addressing(:host, :right), do: [device: "/dev/video0"]
  # Both CSI modules are mounted right-way-up on the OVCS Mini stereo
  # bar, so no in-pipeline rotation. They were previously upside down
  # and carried `rotation: 180`; leaving that in place after the
  # re-mount inverted every published frame — which the calibrator
  # shows plainly, and which would have baked a wrong orientation into
  # the intrinsics. Re-check this whenever the bar is re-mounted.
  # libcamera's camera_id 0 is the physically *right* module on this
  # bar, not the left. Verified two ways, because a transposed pair
  # still yields a plausible-looking disparity map rather than an
  # obvious failure: covering the left lens darkened /stereo/right,
  # and ORB matches between the two frames put the median
  # `x_left - x_right` at -86 px (0 of 292 matches positive, where a
  # correctly ordered pair must be entirely positive).
  defp camera_addressing(:target, :left), do: [camera_id: 1]
  defp camera_addressing(:target, :right), do: [camera_id: 0]

  defp priv_calibration_dir do
    case :code.priv_dir(:ovcs_mini) do
      {:error, :bad_name} -> "priv/calibration"
      dir -> Path.join(List.to_string(dir), "calibration")
    end
  end
end
