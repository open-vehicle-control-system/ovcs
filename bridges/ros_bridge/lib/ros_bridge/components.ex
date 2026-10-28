defmodule RosBridge.Components do
  @moduledoc """
  Resolves the symbolic component entries in a vehicle's
  `RosBridge.Config.components` list into supervised child specs.

  Each clause of `start/2` returns a list of one or more child specs
  for the named component. Vehicles compose `ros_bridge` by listing
  the components they want; adding a new feature is one new clause
  here plus one opt-in line per vehicle that wants it. No implicit
  defaults — the bridge's runtime shape is exactly what the active
  vehicle declared.

  ## Components

    * `:heartbeat` — `RosBridge.Publishers.Heartbeat` publishing a 1 Hz
      `std_msgs/String` on `/ovcs_heartbeat`. Opts:
        * `:interval_ms` (default `1_000`)
    * `:joy_interpreter` — `RosBridge.Consumers.Joy` subscribing to
      the framework's joystick profiles (`priv/joy`) and forwarding
      axes onto the CAN bus. Options: `:profiles_dir`, a directory of
      the vehicle's own profile files (see `RosBridge.Consumers.Joy`).
    * `:velocity_interpreter` — `RosBridge.Consumers.Velocity`
      subscribing to a velocity-command topic (`cmd_vel` by default,
      `geometry_msgs/TwistStamped`) and emitting `ros_velocity_command`
      (`0x2B1`). The planner-shaped counterpart to
      `:joy_interpreter`: it forwards linear and angular velocity so
      the VMS solves the kinematics once against its own geometry.
      Options: `:topic`, `:message`, `:timeout_ms`.
    * `:simulator_clock` — `RosBridge.Clock`, following `/clock` so
      published stamps use simulator time rather than wall clock.
      **Simulation only.** Without it every stamp is wall clock, which
      is correct on a vehicle and wrong against Gazebo — see
      `RosBridge.Clock` for what that breaks.
    * `:simulated_hardware` — `RosBridge.Simulator.Hardware`, emulating the
      vehicle's hardware on CAN so the VMS drives a simulated vehicle.
      **Simulation only.** Opts: `:vehicle`, `:simulated_components`
      (required), `:drive_topic`, `:wheel_joints`; see the module.
    * `:imu_publisher` — starts the named driver (any
      `OvcsDrivers.Imu` implementation) followed by
      `RosBridge.Publishers.Imu`. Opts:
        * `:driver` (required, module — `OvcsDrivers.Imu.Dummy`,
          `BNO085.I2C`, etc.)
        * `:topic`, `:frame_id`, `:publish_interval_ms` — forwarded
          to `RosBridge.Publishers.Imu` (see its defaults).
    * `:lidar_publisher` — starts the named driver (any
      `OvcsDrivers.Lidar` implementation) followed by
      `RosBridge.Publishers.LaserScan`. Opts:
        * `:driver` (required, module — `RPLidar.UART`,
          `RosBridge.Lidar.Zenoh`)
        * `:driver_opts` — forwarded to the driver (`device:`, ...)
        * `:topic`, `:frame_id`, `:bins` — forwarded to
          `RosBridge.Publishers.LaserScan` (see its defaults).
    * `:range_publisher` — one rangefinder: starts the named driver
      instance (any `OvcsDrivers.Rangefinder` implementation) followed
      by `RosBridge.Publishers.Range`. List it once per sensor. Opts:
        * `:driver` (required, module — `A02YYUW.UART`,
          `RosBridge.Rangefinder.Zenoh`)
        * `:name` (required) — the instance's name, unique per sensor
        * `:driver_opts` — forwarded to the driver (`serial_number:`, ...)
        * `:topic`, `:frame_id` (required), `:radiation_type`,
          `:beyond_range`
    * `:odometry_publisher` — `RosBridge.Publishers.Odometry`,
      dead-reckoning `/odom` and the `odom → base_link` transform from
      the VMS's `vehicle_motion` CAN frame and the IMU heading. Opts:
        * `:driver` (required, module) — the **already running** IMU
          driver; list `:imu_publisher` first, it starts the driver.
        * `:topic`, `:odom_frame_id`, `:base_frame_id`,
          `:stale_after_ms`, `:base_ahead_of_rear_axle` — see the module.
    * `:ackermann_joint_states` — `RosBridge.Publishers.AckermannJointStates`,
      an Ackermann vehicle's steered and rolling wheels on
      `/joint_states` from the VMS's `vehicle_motion` CAN frame, for
      `robot_state_publisher`. Not against a simulator, which publishes
      its own. Opts: `:steering_joints`, `:wheel_joints`, `:wheelbase`,
      `:kingpin_width`, `:wheel_radius` (required), `:topic` — see the
      module.
    * `:vehicle_status_publisher` — `RosBridge.Publishers.VehicleStatus`,
      the VMS's status, gear and control level on `/vehicle/*`, from the
      `vms_status`, `gear_status` and `control_status` CAN frames the
      vehicle's bridge topology receives. Opts: `:topic_prefix`.
    * `:static_transforms` — publishes the vehicle's fixed frame
      relationships on `/tf_static`, republished at 1 Hz. Opts: `:transforms` (required, a list of
      `%{parent:, child:, translation: {x,y,z}, rotation: {x,y,z,w}}`),
      plus `:topic` and `:interval_ms`. Without it, frame ids in
      message headers are labels a consumer cannot resolve — see
      `RosBridge.Publishers.StaticTransform`.
    * `:stereo_camera` — self-contained stereo perception unit
      (cameras + per-side image/camera_info publishers + SGBM
      backend + disparity/depth publisher). All orchestration
      lives in `RosBridge.StereoCamera.Supervisor`; see that
      module's `@moduledoc` for the authoritative opts reference.
      Minimal vehicle wiring looks like:

          {:stereo_camera,
           driver: RosBridge.Camera.GStreamer,
           calibration_dir: :code.priv_dir(:ovcs_mini)
                            |> Path.join("calibration"),
           left:  [device: "/dev/video2"],
           right: [device: "/dev/video0"]}

      Resolution defaults to 1280×720@30, topic prefix to
      `"stereo"` (matching the ROS `stereo_image_proc` convention),
      and per-side `frame_id` / `calibration_path` to values
      derived from `:topic_prefix` and `:calibration_dir`. The
      stereo-depth backend is `RosBridge.StereoCamera.OpenCV`.
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises on
  unknown names so a typo in a vehicle's `:components` list fails
  loudly at boot.
  """
  def start(:heartbeat, opts) do
    [
      {RosBridge.Publishers.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2Zenoh.StdMsgs.Msg.String,
       interval_ms: Keyword.get(opts, :interval_ms, 1_000),
       build: &heartbeat_message/2}
    ]
  end

  def start(:simulator_clock, opts), do: [{RosBridge.Clock, opts}]

  def start(:simulated_hardware, opts), do: [{RosBridge.Simulator.Hardware, opts}]

  def start(:joy_interpreter, opts), do: [{RosBridge.Consumers.Joy, opts}]

  def start(:velocity_interpreter, opts), do: [{RosBridge.Consumers.Velocity, opts}]

  def start(:imu_publisher, opts) do
    driver = Keyword.fetch!(opts, :driver)
    [{driver, []}, {RosBridge.Publishers.Imu, opts}]
  end

  def start(:lidar_publisher, opts) do
    driver = Keyword.fetch!(opts, :driver)
    [{driver, Keyword.get(opts, :driver_opts, [])}, {RosBridge.Publishers.LaserScan, opts}]
  end

  def start(:range_publisher, opts) do
    driver = Keyword.fetch!(opts, :driver)
    name = Keyword.fetch!(opts, :name)

    [
      {driver, Keyword.put(Keyword.get(opts, :driver_opts, []), :name, name)},
      {RosBridge.Publishers.Range, opts}
    ]
  end

  def start(:odometry_publisher, opts) do
    # Fetched only to fail at boot when missing; `:imu_publisher` starts the driver.
    _driver = Keyword.fetch!(opts, :driver)
    [{RosBridge.Publishers.Odometry, opts}]
  end

  def start(:ackermann_joint_states, opts) do
    [{RosBridge.Publishers.AckermannJointStates, opts}]
  end

  def start(:vehicle_status_publisher, opts) do
    [{RosBridge.Publishers.VehicleStatus, opts}]
  end

  def start(:static_transforms, opts) do
    [{RosBridge.Publishers.StaticTransform, opts}]
  end

  def start(:hailo_detector, opts) do
    start(:detector, Keyword.put_new(opts, :backend, RosBridge.Inference.Hailo))
  end

  def start(:detector, opts) do
    # Its own supervisor, so a crashing detector cannot exhaust the bridge's restart budget.
    [{RosBridge.Inference.Supervisor, opts}]
  end

  def start(:stereo_camera, opts) do
    [{RosBridge.StereoCamera.Supervisor, opts}]
  end

  defp heartbeat_message(counter, node_name) do
    %Ros2Zenoh.StdMsgs.Msg.String{
      data: "#{node_name} heartbeat #{counter} @ #{System.system_time(:millisecond)}"
    }
  end
end
