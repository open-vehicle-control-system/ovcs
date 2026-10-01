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
  # Measured, in metres and radians. These are declared twice on
  # purpose: here, and as `<xacro:property>` values in
  # `description/ovcs_mini.urdf.xacro`, because xacro cannot read
  # Elixir and the simulator needs them at model-generation time.
  #
  # `test/geometry_test.exs` asserts the two declarations agree, which
  # is what makes the duplication safe rather than silent. That check
  # is not decoration: a wheel radius wrong by 2x already shipped in
  # this model once, drove convincingly, and reported nonsense — see
  # `compose/local/simulation/scripts/drive_test.py`.
  @impl OvcsVehicle
  def geometry,
    do: %{
      wheelbase: 0.324,
      track: 0.296,
      wheel_radius: 0.0522,
      steering_limit: 0.52
    }

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
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:vcan0"},
        # Not committed: `mise run fetch-models`.
        required_files: ["priv/models/#{hailo_model()}.hef"]
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
  def ros_bridge_config(:host, "ros_perception") do
    if System.get_env("OVCS_SIM") in ["1", "true"] do
      perception_sim_config()
    else
      perception_host_config()
    end
  end

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
  defp ros_host_config do
    sim? = System.get_env("OVCS_SIM") in ["1", "true"]

    # Against the simulator the IMU driver is the simulated BNO085 —
    # Gazebo publishes it on `imu_raw`, `RosBridge.Imu.Zenoh` consumes
    # it, and `/imu` is still published by this bridge's own
    # `Publishers.Imu`, exactly as on the vehicle. Only the driver
    # changes, the same pattern as the cameras.
    imu_driver = if sim?, do: RosBridge.Imu.Zenoh, else: OvcsDrivers.Imu.Dummy

    components = [
      :heartbeat,
      :joy_interpreter,
      # Nav2 publishes TwistStamped on /cmd_vel_nav; teleop_twist_joy
      # publishes plain Twist on /cmd_vel. Subscribing to the stamped
      # one keeps the joystick path on 0x2B0 and the planner path on
      # 0x2B1, so both can be present without racing.
      {:velocity_interpreter,
       %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
      {:imu_publisher, driver: imu_driver}
    ]

    # Against the simulator, Gazebo's AckermannSteering already
    # publishes /odom and odom -> base_link, and a second publisher on
    # either would hand every consumer two contradictory poses — the
    # tf tree interpolates across both rather than picking a winner.
    # One odometry owner per fabric: the bench (no Gazebo) gets this
    # bridge's dead reckoning, a simulated run gets Gazebo's.
    odometry =
      if sim? do
        []
      else
        # After :imu_publisher, which starts the driver this listens
        # to. Reads the VMS's vehicle_motion frame off CAN and
        # publishes /odom and odom -> base_link for the mapping stack.
        [
          {:odometry_publisher,
           driver: OvcsDrivers.Imu.Dummy, base_offset_x: geometry().wheelbase / 2},
          rear_axle_transform()
        ]
      end

    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: components ++ odometry
    }
  end

  defp ros_target_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :heartbeat,
        :joy_interpreter,
        # Same subscription as the host config. This is the list the
        # burned firmware runs, so the planner path exists on the
        # vehicle only if it is declared here as well.
        {:velocity_interpreter,
         %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
        {:imu_publisher, driver: BNO085.I2C},
        # Same ordering constraint as the host config.
        {:odometry_publisher, driver: BNO085.I2C, base_offset_x: geometry().wheelbase / 2},
        rear_axle_transform()
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

  # The same perception stack, fed by Gazebo instead of by cameras.
  #
  # Only the driver changes. The SGBM backend, the rectification, the
  # publishers and the detector are the code that runs on the car, and
  # that is the point of simulating at all — a pipeline that behaved
  # differently under simulation would not be evidence of anything.
  #
  # No `:hailo_detector`: there is no accelerator on a workstation. It
  # would start, log that it is unavailable and publish nothing, which
  # is correct but pointless.
  #
  # Chosen with VEHICLE=OvcsMini and OVCS_SIM=1, so the sim wiring
  # cannot be selected by accident on the vehicle.
  defp perception_sim_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_perception_sim",
      components:
        [
          :heartbeat,
          # First, and only here. Gazebo owns the clock in simulation,
          # so every stamp this bridge publishes has to be on
          # simulator time or it will not line up with /tf and /odom —
          # Nav2's costmaps drop point clouds that do not. On the
          # vehicle there is no /clock and wall clock is correct, which
          # is why this appears in no other configuration.
          :simulator_clock,
          stereo_transforms(),
          stereo_component(RosBridge.Camera.Zenoh, :sim)
        ] ++ sim_detector()
    }
  end

  # Detection on a workstation, so the sim runs the *whole* stack
  # rather than everything-but-the-detector. Off unless a model is
  # present: the ONNX weights are not in the repo, so the default
  # remains a stereo-only sim rather than a detector that logs a
  # missing file on every start.
  #
  # OVCS_DETECTOR picks the backend, defaulting to the DNN one when a
  # model exists:
  #
  #   dnn        CPU inference
  #   gpu        the same model through OpenCL — see
  #              `RosBridge.Inference.Dnn` on why that is worth less on
  #              NVIDIA than CUDA would be
  #   stub       fabricated boxes, for testing the depth fusion and the
  #              markers with no model at all
  #   off        no detector
  #
  # `detect_every_n: 3` because CPU inference shares this machine with
  # SGBM and Gazebo. On the car the accelerator runs every frame.
  defp sim_detector do
    case sim_detector_choice() do
      :off ->
        []

      :stub ->
        [{:detector, backend: RosBridge.Inference.Stub, frame_id: "stereo_left"}]

      target ->
        [
          {:detector,
           backend: RosBridge.Inference.Dnn,
           model_path: sim_model_path(),
           target: target,
           score_threshold: 0.4,
           detect_every_n: 3,
           frame_id: "stereo_left"}
        ]
    end
  end

  defp sim_detector_choice do
    case System.get_env("OVCS_DETECTOR") do
      "gpu" -> :opencl_fp16
      "dnn" -> :cpu
      "stub" -> :stub
      "off" -> :off
      # Unset: only if the weights are actually there.
      _ -> if File.exists?(sim_model_path()), do: :cpu, else: :off
    end
  end

  defp sim_model_path, do: Path.join(priv_models_dir(), "yolov8n.onnx")

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

  defp rear_axle_transform do
    {:static_transforms,
     transforms: [
       %{
         parent: "base_link",
         child: "rear_axle",
         translation: {-geometry().wheelbase / 2, 0.0, 0.0},
         rotation: {0.0, 0.0, 0.0, 1.0}
       }
     ]}
  end

  # The left lens is 45 mm left of the centreline and 185 mm above ground.
  defp stereo_transforms do
    {:static_transforms,
     transforms: [
       %{
         parent: "base_link",
         child: "stereo_left",
         translation: {0.042, 0.045, 0.185},
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
    {
      :hailo_detector,
      # 0.4 is where a yolov8n at this resolution stops reporting
      # furniture as animals. Measured at 480x270 the model still
      # scores real people at 0.74-0.91, so this leaves plenty of
      # headroom above the noise.
      #
      # That measurement is yolov8n's. It has *not* been re-taken for
      # the NanoDet default, so treat 0.4 as a starting point there
      # rather than a tuned value.
      # The stereo unit's own frame, since boxes are positioned in its
      # rectified pixels.
      hef_path: Path.join(priv_models_dir(), "#{hailo_model()}.hef"),
      score_threshold: 0.4,
      frame_id: "stereo_left"
    }
  end

  # NanoDet-RepVGG by default, because it is Apache-2.0 and YOLOv8 is
  # AGPL-3.0 — see the Model licensing section of
  # docs/ros2_perception.md. The swap needs no code: both
  # carry the same in-graph NMS net flow, and `hailo_detect` reads the
  # input size and class count off the HEF rather than assuming them.
  #
  # `OVCS_HAILO_MODEL=yolov8n` selects the original for anyone holding
  # an Ultralytics licence. Whatever is named here has to be in
  # `scripts/models.tsv` so `mise run fetch-models` can fetch it.
  defp hailo_model, do: System.get_env("OVCS_HAILO_MODEL", "nanodet_repvgg")

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
    {
      :stereo_camera,
      # Keep the calibration's 16:9 aspect. At 480x270, 96 disparities
      # give a 0.55 m near limit. Pair within 20 ms to limit motion mismatch.
      # Spatial disparity filtering feeds both the depth image and cloud.
      driver: camera_driver,
      calibration_dir: priv_calibration_dir(arm),
      width: 480,
      height: 270,
      fps: 30,
      pair_tolerance_ms: 20,
      publish_rectified_image: true,
      backend_opts: [
        num_disparities: 96,
        block_size: 9,
        speckle_window_size: 300,
        speckle_range: 12
      ],
      left: camera_addressing(arm, :left),
      right: camera_addressing(arm, :right)
    }
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

  # In simulation the "camera" is a topic. Gazebo publishes on the
  # same names the vehicle does, so left really is left here — the
  # transposition that catches physical modules cannot happen.
  defp camera_addressing(:sim, side),
    do: [topic: "/stereo/#{side}/image_raw/compressed"]

  # The simulator gets its own calibration, and must: Gazebo renders an
  # ideal pinhole, so applying the physical lens's distortion and
  # rectification to it warps the two views apart rather than into
  # alignment. Measured, that dropped stereo coverage to 5.4%.
  defp priv_calibration_dir(:sim), do: Path.join(priv_calibration_dir(), "sim")
  defp priv_calibration_dir(_arm), do: priv_calibration_dir()

  defp priv_calibration_dir do
    case :code.priv_dir(:ovcs_mini) do
      {:error, :bad_name} -> "priv/calibration"
      dir -> Path.join(List.to_string(dir), "calibration")
    end
  end
end
