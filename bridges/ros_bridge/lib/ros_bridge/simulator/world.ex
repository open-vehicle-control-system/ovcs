defmodule RosBridge.Simulator.World do
  @moduledoc """
  Gazebo, as the world that moves `SimulatorCore.Hardware`'s vehicle.
  **Simulation only.**

  It publishes the vehicle's speed and Ackermann yaw rate as a
  `geometry_msgs/Twist` on `simulator/drive`, which the simulator's own
  drive plugin follows, and reads how far the wheels turned as the
  `:wheel_joints`' mean position on `joint_states`, which the simulator
  integrates.

  ## Options

    * `:wheel_joints` (`[]`) — the joints the drive turns, each positive
      when rolling forward; none for no measurement.
  """
  @behaviour SimulatorCore.World

  alias Ros2Zenoh.GeometryMsgs.Msg.{Twist, Vector3}
  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias SimulatorCore.Vehicle

  @impl SimulatorCore.World
  def init(opts) do
    wheel_joints = opts |> Map.new() |> Map.get(:wheel_joints, [])
    if wheel_joints != [], do: :ok = Ros2Zenoh.Client.subscribe("joint_states", JointState)
    %{wheel_joints: wheel_joints}
  end

  @impl SimulatorCore.World
  def wheel_turns({:ros_message, {_key_expr, %JointState{} = joint_state}}, state),
    do: mean_turns(joint_state, state.wheel_joints)

  def wheel_turns(_message, _state), do: nil

  @impl SimulatorCore.World
  def drive(vehicle, _state) do
    # The client logs a message it cannot encode; the next tick sends another.
    _ = Ros2Zenoh.Client.publish("simulator/drive", Twist, twist(vehicle))
    :ok
  end

  @doc """
  The drive Gazebo's `AckermannSteering` follows: the commanded speed
  and the yaw rate of an Ackermann vehicle at that speed and steering.
  Pure.
  """
  def twist(%Vehicle{} = vehicle) do
    yaw_rate =
      vehicle.commanded_speed_m_s * :math.tan(vehicle.steering_rad) / vehicle.wheelbase_m

    %Twist{
      linear: %Vector3{x: vehicle.commanded_speed_m_s, y: 0.0, z: 0.0},
      angular: %Vector3{x: 0.0, y: 0.0, z: yaw_rate}
    }
  end

  # nil if one of the joints is missing.
  defp mean_turns(%JointState{name: names, position: positions}, wheel_joints) do
    by_name = Enum.zip(names, positions) |> Map.new()
    radians = Enum.map(wheel_joints, &Map.get(by_name, &1))

    if nil in radians,
      do: nil,
      else: Enum.sum(radians) / length(radians) / (2 * :math.pi())
  end
end
