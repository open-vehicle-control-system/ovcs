defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge
  @behaviour OvcsBusGateway

  alias OvcsVehicle.URDF

  @impl OvcsVehicle
  def name, do: "OVCS Mini"
  @impl OvcsVehicle
  def vms, do: OvcsMini.Vms.Composer
  @urdf_path Path.expand("../description/ovcs_mini.urdf", __DIR__)
  @external_resource @urdf_path
  @urdf URDF.read!(@urdf_path)

  # Read off the URDF, which `mise run urdf` expands from the xacro.
  @impl OvcsVehicle
  def geometry do
    {front_x, _, _} = URDF.joint!(@urdf, "front_left_steering_joint").xyz
    {_, inner_wheel_limit} = URDF.joint!(@urdf, "front_left_steering_joint").limit
    {rear_x, rear_left, _} = URDF.joint!(@urdf, "rear_left_wheel_joint").xyz
    {_, rear_right, _} = URDF.joint!(@urdf, "rear_right_wheel_joint").xyz
    wheelbase = front_x - rear_x
    turning_radius = wheelbase / :math.tan(inner_wheel_limit) + kingpin_width() / 2

    %{
      wheelbase: wheelbase,
      track: rear_left - rear_right,
      wheel_radius: URDF.collision_cylinder!(@urdf, "rear_left_wheel").radius,
      # The bicycle model's angle at the inner wheel's limit.
      steering_limit: :math.atan(wheelbase / turning_radius)
    }
  end

  # The steering pivots' spacing.
  defp kingpin_width do
    {_, left, _} = URDF.joint!(@urdf, "front_left_steering_joint").xyz
    {_, right, _} = URDF.joint!(@urdf, "front_right_steering_joint").xyz
    left - right
  end

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
      # On the host it also declares the frames of the hardware its
      # simulated hardware answers for, see `ros_bridge_simulation_config/0`.
      "ros" => %{
        target: :ovcs_base_can_system_rpi4,
        bridges: [RosBridge, OvcsBusGateway],
        can_config_path: %{
          host: ["can/bridges/ros.yml", "can/bridges/ros_simulated_components.yml"],
          target: "can/bridges/ros.yml"
        },
        default_can_mapping: %{host: "ovcs:vcan0,misc:vcan1", target: "ovcs:spi0.0"}
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
      "ros_vision" => %{
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
  def ros_bridge_config(:host, "ros_vision") do
    if simulation?(),
      do: ros_vision_bridge_simulation_config(),
      else: ros_vision_bridge_host_config()
  end

  def ros_bridge_config(:target, "ros_vision"),
    do: ros_vision_bridge_target_config()

  def ros_bridge_config(:host, _firmware_id) do
    if simulation?(), do: ros_bridge_simulation_config(), else: ros_bridge_host_config()
  end

  def ros_bridge_config(:target, _firmware_id),
    do: ros_bridge_target_config()

  @impl OvcsBusGateway
  def ovcs_bus_gateway_config(:host),
    do: %OvcsBusGateway.Config{
      mqtt: [host: System.get_env("MQTT_HOST", "127.0.0.1"), port: 1883]
    }

  def ovcs_bus_gateway_config(:target),
    do: %OvcsBusGateway.Config{
      mqtt: [host: Application.get_env(:ovcs_bus_gateway, :mqtt_host, "127.0.0.1"), port: 1883]
    }

  defp simulation?, do: System.get_env("OVCS_SIM") in ["1", "true"]

  # The Mini runs two ROS bridges on one Zenoh fabric (this one and
  # the perception Pi), so each names its ROS node explicitly —
  # otherwise both announce `ovcs_bridge` and the ROS graph cannot
  # tell them apart.
  defp ros_bridge_host_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :heartbeat,
        :vehicle_status_publisher,
        :joy_interpreter,
        # Nav2 publishes TwistStamped on /cmd_vel_nav, the planner path
        # on 0x2B1; the joystick path stays on 0x2B0.
        {:velocity_interpreter,
         %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
        {:imu_publisher, driver: OvcsDrivers.Imu.Dummy},
        # After :imu_publisher, which starts the driver this listens
        # to. Reads the VMS's vehicle_motion frame off CAN and
        # publishes /odom and odom -> base_link, which is everything
        # Nav2 needs in the map-less setup.
        {:odometry_publisher,
         driver: OvcsDrivers.Imu.Dummy, base_ahead_of_rear_axle: base_ahead_of_rear_axle()},
        ackermann_joint_states()
      ]
    }

  # base_link sits midway between the axles.
  defp base_ahead_of_rear_axle, do: geometry().wheelbase / 2

  # The `ros` bridge against the simulator, chosen with OVCS_SIM: its
  # simulated hardware answers for the Mini's, so the VMS commands Gazebo's
  # physics over CAN, and the IMU is Gazebo's.
  defp ros_bridge_simulation_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :simulator_clock,
        :heartbeat,
        :vehicle_status_publisher,
        :joy_interpreter,
        {:velocity_interpreter,
         %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
        {:imu_publisher, driver: RosBridge.Imu.Zenoh},
        {:odometry_publisher,
         driver: RosBridge.Imu.Zenoh, base_ahead_of_rear_axle: base_ahead_of_rear_axle()},
        {:lidar_publisher, driver: RosBridge.Lidar.Zenoh, bins: 500, frame_id: "lidar_link"},
        rear_ultrasound(:left, RosBridge.Rangefinder.Zenoh, topic: "ultrasound/rear_left_raw"),
        rear_ultrasound(:right, RosBridge.Rangefinder.Zenoh, topic: "ultrasound/rear_right_raw"),
        {:simulated_hardware, simulated_hardware()}
      ]
    }
  end

  # Not measured: plausible figures for a 1/10 truck on a 2S pack.
  @simulated_battery_voltage 7.4
  @simulated_acceleration_per_ampere 0.5
  # The Mini's VESC Tool setting, see docs/vesc_drivetrain.md.
  @vesc_minimum_erpm 300

  @doc false
  def simulated_acceleration_per_ampere, do: @simulated_acceleration_per_ampere

  defp simulated_hardware do
    drivetrain = OvcsMini.Vms.Composer.drivetrain()

    [
      vehicle: %{
        wheelbase_m: geometry().wheelbase,
        wheel_radius_m: geometry().wheel_radius,
        # Friction is the motor current the Mini needs to start rolling.
        rolling_deceleration_m_s2:
          drivetrain.min_motor_current * @simulated_acceleration_per_ampere
      },
      # Shaft-driven 4WD: the motor turns at the four wheels' mean.
      wheel_joints: ~w(front_left_wheel_joint front_right_wheel_joint
                       rear_left_wheel_joint rear_right_wheel_joint),
      simulated_components: [
        {RosBridge.Simulator.SimulatedComponents.Vesc.MotorController,
         pole_pairs: drivetrain.pole_pairs,
         motor_to_wheel_ratio: drivetrain.motor_to_wheel_ratio,
         min_erpm: @vesc_minimum_erpm,
         acceleration_per_ampere: @simulated_acceleration_per_ampere,
         input_voltage: @simulated_battery_voltage},
        {RosBridge.Simulator.SimulatedComponents.OVCS.GenericController,
         analog_pins: %{1 => pm12s3_reading(@simulated_battery_voltage)},
         pulse: %{
           shaft_turns_per_wheel_turn:
             drivetrain.motor_to_wheel_ratio * drivetrain.pinion_teeth / drivetrain.spur_teeth,
           pulses_per_revolution: drivetrain.pulses_per_revolution
         }},
        {RosBridge.Simulator.SimulatedComponents.Traxxas.Steering,
         steering_limit_rad: geometry().steering_limit,
         steering_sign: drivetrain.steering_sign,
         neutral: drivetrain.steering_trim},
        {RosBridge.Simulator.SimulatedComponents.OVCS.RadioControl, radio_control_script()}
      ]
    ]
  end

  # The PM12S-3's 1:21 divider read by the controller's 14-bit, 5 V ADC.
  defp pm12s3_reading(voltage), do: round(voltage / 21 / 5 * 16_383)

  # Sticks centred, then channel 6 through :radio to :ros, and channel 5
  # to the commander `OVCS_SIMULATOR_COMMANDER` names (`teleop`, or
  # `autonomous` by default), each a second apart.
  defp radio_control_script do
    commander = if System.get_env("OVCS_SIMULATOR_COMMANDER") == "teleop", do: 1000, else: 2000

    [
      channels: %{1 => 1500, 2 => 1500, 5 => 1000, 6 => 1000},
      steps: [{3_000, %{6 => 1500}}, {4_000, %{6 => 2000}}, {5_000, %{5 => commander}}]
    ]
  end

  defp ros_bridge_target_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      node_name: "ovcs_bridge_ros",
      components: [
        :heartbeat,
        :vehicle_status_publisher,
        :joy_interpreter,
        # Same subscription as the host config. This is the list the
        # burned firmware runs, so the planner path exists on the
        # vehicle only if it is declared here as well.
        {:velocity_interpreter,
         %{topic: "cmd_vel_nav", message: Ros2.GeometryMsgs.Msg.TwistStamped}},
        {:imu_publisher, driver: BNO085.I2C},
        # Same ordering constraint as the host config.
        {:odometry_publisher,
         driver: BNO085.I2C, base_ahead_of_rear_axle: base_ahead_of_rear_axle()},
        # RPLIDAR C1 on the bridge's USB port, found by its adapter's
        # serial number. It measures about every 0.72 degrees, 500
        # points a revolution: one bin each.
        {:lidar_publisher,
         driver: RPLidar.UART,
         driver_opts: [serial_number: "bafb4ecd0064ef11858ee0a9c169b110"],
         bins: 500,
         frame_id: "lidar_link"},
        # A02YYUW ultrasonic sensors on the rear bumper, each on a CP2104
        # found by its serial number.
        rear_ultrasound(:left, A02YYUW.UART, serial_number: "01D9EBFA"),
        rear_ultrasound(:right, A02YYUW.UART, serial_number: "02PW2EBP"),
        ackermann_joint_states()
      ]
    }

  # The wheels robot_state_publisher places; Gazebo publishes them in simulation.
  defp ackermann_joint_states do
    {:ackermann_joint_states,
     steering_joints: {"front_left_steering_joint", "front_right_steering_joint"},
     wheel_joints:
       ~w(front_left_wheel_joint front_right_wheel_joint rear_left_wheel_joint rear_right_wheel_joint),
     wheelbase: geometry().wheelbase,
     kingpin_width: kingpin_width(),
     wheel_radius: geometry().wheel_radius}
  end

  defp rear_ultrasound(side, driver, driver_opts) do
    {:range_publisher,
     driver: driver,
     name: :"ultrasound_rear_#{side}",
     driver_opts: driver_opts,
     topic: "ultrasound/rear_#{side}",
     frame_id: "ultrasound_rear_#{side}_link",
     beyond_range: :max_range}
  end

  defp ros_vision_bridge_host_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros_vision",
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
  # Chosen with VEHICLE=OvcsMini and OVCS_SIM=1, so the simulation wiring
  # cannot be selected by accident on the vehicle.
  defp ros_vision_bridge_simulation_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      node_name: "ovcs_bridge_ros_vision",
      components:
        [
          :heartbeat,
          # Gazebo owns the clock: stamps on its time line up with /tf
          # and /odom, which Nav2's costmaps require.
          :simulator_clock,
          stereo_component(RosBridge.Camera.Zenoh, :simulation)
        ] ++ simulation_detector()
    }
  end

  # Detection on a workstation, so the simulation runs the *whole* stack
  # rather than everything-but-the-detector. Off unless a model is
  # present: the ONNX weights are not in the repo, so the default
  # remains a stereo-only simulation rather than a detector that logs a
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
  defp simulation_detector do
    case simulation_detector_choice() do
      :off ->
        []

      :stub ->
        [{:detector, backend: RosBridge.Inference.Stub, frame_id: "stereo_left_optical"}]

      target ->
        [
          {:detector,
           backend: RosBridge.Inference.Dnn,
           model_path: simulation_model_path(),
           target: target,
           score_threshold: 0.4,
           detect_every_n: 3,
           frame_id: "stereo_left_optical"}
        ]
    end
  end

  defp simulation_detector_choice do
    case System.get_env("OVCS_DETECTOR") do
      "gpu" -> :opencl_fp16
      "dnn" -> :cpu
      "stub" -> :stub
      "off" -> :off
      # Unset: only if the weights are actually there.
      _ -> if File.exists?(simulation_model_path()), do: :cpu, else: :off
    end
  end

  defp simulation_model_path, do: Path.join(priv_models_dir(), "yolov8n.onnx")

  defp ros_vision_bridge_target_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      node_name: "ovcs_bridge_ros_vision",
      components: [
        :heartbeat,
        stereo_component(RosBridge.Camera.LibCamera, :target),
        # After :stereo_camera — the detector registers on that
        # unit's backend while starting.
        hailo_detector()
      ]
    }
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
      frame_id: "stereo_left_optical"
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
  # `StereoCamera.OpenCV`, topic prefix `"stereo"`, calibration paths
  # `<calibration_dir>/stereo_<side>.yaml`), with the URDF's optical
  # frames as frame_ids. We override resolution
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
      #   640x360   f*B 46.0   clip 0.48 m   SGBM ~141 ms
      #   480x270   f*B 34.5   clip 0.36 m   SGBM  ~79 ms
      #
      # The price is depth precision at distance, since dZ = Z^2 dd /
      # (f*B): about 5.8 cm at 2 m against 4.3 cm at 640 wide. Fine for
      # deciding whether to stop for something; not fine for mapping.
      # Wide enough for the unsynchronized USB cameras on host;
      # drop to 5 ms once the perception target has FSIN-tied CSI
      # modules.
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
      # block_size and speckle filtering are tuned against the failure
      # that matters to the costmap: not missing pixels but confident
      # wrong ones. Thin and repetitive structure (a pole, cabinet
      # doors, shelving) false-matches to a disparity far too large,
      # and reads as an obstacle about a metre ahead. A hole is honest;
      # a phantom obstacle is not. Keep CLAHE: without it those
      # phantoms multiply.
      # The rectified pair, to check the calibration's row alignment.
      # No raw images in simulation: Gazebo already publishes the frames
      # Camera.Zenoh reads there.
      driver: camera_driver,
      calibration_dir: priv_calibration_dir(arm),
      calibration_store_dir: calibration_store_dir(arm),
      width: 480,
      height: 270,
      fps: 30,
      pair_tolerance_ms: 100,
      publish_rectified_image: true,
      publish_raw_images: arm != :simulation,
      backend_opts: [
        num_disparities: 96,
        block_size: 9,
        speckle_window_size: 600,
        speckle_range: 8,
        # Rejects the ambiguous matches that land walls and furniture
        # nearer than they are; the smoothness penalties fill in more,
        # and wrongly without it.
        uniqueness_ratio: 20,
        clahe_clip_limit: 3.0
      ],
      left: [frame_id: "stereo_left_optical"] ++ camera_addressing(arm, :left),
      right: [frame_id: "stereo_right_optical"] ++ camera_addressing(arm, :right)
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
  #
  # The left camera leads the software sync and the right one follows it.
  # Short exposures: the normal mode's 30 ms smears the edges SGBM
  # matches as soon as the car moves. Focus is fixed at 1 m, the
  # distances the costmaps care about; the calibration is only valid
  # for these positions. The 2304x1296 sensor mode bins the whole
  # sensor; libcamera's own pick for this output is a centre crop with
  # a third less field of view.
  defp camera_addressing(:target, :left),
    do: [
      camera_id: 1,
      sync: :server,
      exposure_mode: :short,
      lens_position: 1.0,
      sensor_mode: {2304, 1296}
    ]

  defp camera_addressing(:target, :right),
    do: [
      camera_id: 0,
      sync: :client,
      exposure_mode: :short,
      lens_position: 1.0,
      sensor_mode: {2304, 1296}
    ]

  # In simulation the "camera" is a topic. Gazebo publishes on the
  # same names the vehicle does, so left really is left here — the
  # transposition that catches physical modules cannot happen.
  defp camera_addressing(:simulation, side),
    do: [topic: "/stereo/#{side}/image_raw/compressed"]

  # The simulator gets its own calibration, and must: Gazebo renders an
  # ideal pinhole, so applying the physical lens's distortion and
  # rectification to it warps the two views apart rather than into
  # alignment. Measured, that dropped stereo coverage to 5.4%.
  defp priv_calibration_dir(:simulation), do: Path.join(priv_calibration_dir(), "simulation")
  defp priv_calibration_dir(_arm), do: priv_calibration_dir()

  # The firmware's root filesystem is read-only: a calibration
  # committed from cameracalibrator goes to the data partition.
  defp calibration_store_dir(:target), do: "/data/calibration"
  defp calibration_store_dir(_arm), do: nil

  defp priv_calibration_dir do
    case :code.priv_dir(:ovcs_mini) do
      {:error, :bad_name} -> "priv/calibration"
      dir -> Path.join(List.to_string(dir), "calibration")
    end
  end
end
