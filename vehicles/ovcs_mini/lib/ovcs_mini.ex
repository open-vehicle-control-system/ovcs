defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side. Its vision unit is a Raspberry Pi 5,
  built with `./ovcs build ovcs_mini vision`; see `OvcsMini.Vision.Composer`.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge

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
  def vision, do: OvcsMini.Vision.Composer
  @impl OvcsVehicle
  def vision_target, do: :rpi5

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
        bridges: [RosBridge],
        children: %{host: [bus_gateway(:host)], target: [bus_gateway(:target)]},
        can_config_path: %{
          host: ["can/bridges/ros.yml", "can/bridges/ros_simulated_components.yml"],
          target: "can/bridges/ros.yml"
        },
        default_can_mapping: %{host: "ovcs:vcan0,misc:vcan1", target: "ovcs:spi0.0"}
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
  def ros_bridge_config(:host) do
    if simulation?(), do: ros_bridge_simulation_config(), else: ros_bridge_host_config()
  end

  def ros_bridge_config(:target), do: ros_bridge_target_config()

  defp bus_gateway(arm) do
    {OvcsBusGateway,
     vehicle: __MODULE__,
     config: %OvcsBusGateway.Config{mqtt: [host: mqtt_broker(arm), port: 1883]},
     mqtt_client_id: "ovcs_bus_gateway_ovcs_mini_ros_#{arm}"}
  end

  defp mqtt_broker(:host), do: "127.0.0.1"
  # The compute node's fixed address on the vehicle network, the one `.env.exs` gives Zenoh.
  defp mqtt_broker(:target), do: "10.42.0.1"

  defp simulation?, do: System.get_env("OVCS_SIM") in ["1", "true"]

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
         %{topic: "cmd_vel_nav", message: Ros2Zenoh.GeometryMsgs.Msg.TwistStamped}},
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
         %{topic: "cmd_vel_nav", message: Ros2Zenoh.GeometryMsgs.Msg.TwistStamped}},
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
  # The Mini's VESC Tool setting, see docs/vms/drivers.md.
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
         %{topic: "cmd_vel_nav", message: Ros2Zenoh.GeometryMsgs.Msg.TwistStamped}},
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
end
