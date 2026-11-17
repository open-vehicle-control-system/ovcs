defmodule RosBridge.Simulator.World do
  @moduledoc """
  Gazebo, as the world of `SimulatorCore.Hardware`. **Simulation only.**

  Until Gazebo takes the actuator efforts itself (TASK-130), this world
  turns them into a speed with its own `SimulatorCore.FlatGround`, and
  publishes that speed and its Ackermann yaw rate as a
  `geometry_msgs/Twist` on `simulator/drive`, which Gazebo's drive
  plugin follows. It reports each wheel as Gazebo measures it: its
  angle from `joint_states`, from where the first message found it, so
  a Gazebo that ran before the bridge started counts nothing it did
  then; its spin from the angle's change since the previous message
  over the wall clock the VMS measures against. A message in the same
  millisecond as the previous one is skipped, the next one measuring
  over both.

  Its speed leads the wheels Gazebo measures by at most 0.25 m/s in
  its own direction: against a wall Gazebo stalls
  the wheels, and the speed holds there instead of winding up.

  ## Options

    * `:vehicle` (required) — `SimulatorCore.FlatGround.new/1`'s
      parameters.
    * `:wheel_joints` (required) — the Gazebo joint of each wheel, keyed
      as `SimulatorCore.WorldState` names them, each positive when
      rolling forward.
  """
  @behaviour SimulatorCore.World

  alias Ros2Zenoh.GeometryMsgs.Msg.{Twist, Vector3}
  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias SimulatorCore.{FlatGround, WorldState}

  @speed_lead_m_s 0.25

  @impl SimulatorCore.World
  def init(opts) do
    opts = Map.new(opts)
    vehicle = Map.fetch!(opts, :vehicle)
    :ok = Ros2Zenoh.Client.subscribe("joint_states", JointState)

    %{
      wheel_joints: Map.fetch!(opts, :wheel_joints),
      ground: FlatGround.new(vehicle),
      wheel_radius_m: Map.fetch!(vehicle, :wheel_radius_m),
      start: nil,
      previous: nil,
      clock: fn -> System.monotonic_time(:millisecond) end
    }
  end

  @impl SimulatorCore.World
  def actuate(efforts, dt_s, state) do
    state = step(state, efforts, dt_s)
    # The client logs a message it cannot encode; the next tick sends another.
    _ = Ros2Zenoh.Client.publish("simulator/drive", Twist, twist(state.ground))
    state
  end

  @impl SimulatorCore.World
  def world_state({:ros_message, {_key_expr, %JointState{} = joint_state}}, state) do
    now_ms = state.clock.()

    case {angles(joint_state, state.wheel_joints), state.previous} do
      {nil, _previous} -> nil
      {_angles, {_previous, at_ms}} when now_ms <= at_ms -> nil
      {angles, _previous} -> measured(state, angles, now_ms)
    end
  end

  def world_state(_message, _state), do: nil

  @doc "Moves its flat ground under `efforts` for `dt_s`. Pure."
  def step(state, efforts, dt_s),
    do: %{state | ground: FlatGround.step(state.ground, efforts, dt_s)}

  @doc """
  The drive Gazebo's `AckermannSteering` follows: the ground's speed and
  the yaw rate of an Ackermann vehicle at that speed and steering. Pure.
  """
  def twist(%FlatGround{} = ground) do
    %Twist{
      linear: %Vector3{x: ground.speed_m_s, y: 0.0, z: 0.0},
      angular: %Vector3{x: 0.0, y: 0.0, z: ground.speed_m_s * FlatGround.curvature(ground)}
    }
  end

  defp measured(state, angles, now_ms) do
    start = state.start || angles

    spins =
      case state.previous do
        {previous, at_ms} ->
          Map.new(angles, fn {wheel, angle} ->
            {wheel, (angle - previous[wheel]) / ((now_ms - at_ms) / 1000)}
          end)

        nil ->
          Map.new(angles, fn {wheel, _angle} -> {wheel, 0.0} end)
      end

    wheels =
      Map.new(angles, fn {wheel, angle} ->
        {wheel, %{angle_rad: angle - start[wheel], omega_rad_s: spins[wheel], in_contact: true}}
      end)

    world_state = %{WorldState.at_rest(state.wheel_radius_m) | wheels: wheels}

    measured_m_s =
      WorldState.mean(world_state, Map.keys(wheels)).omega_rad_s * state.wheel_radius_m

    ground = %{state.ground | speed_m_s: lead_limited(state.ground.speed_m_s, measured_m_s)}
    {world_state, %{state | ground: ground, start: start, previous: {angles, now_ms}}}
  end

  defp lead_limited(speed, measured) when speed >= 0,
    do: min(speed, max(measured, 0.0) + @speed_lead_m_s)

  defp lead_limited(speed, measured), do: max(speed, min(measured, 0.0) - @speed_lead_m_s)

  # nil if one of the joints is missing.
  defp angles(%JointState{name: names, position: positions}, wheel_joints) do
    by_name = Enum.zip(names, positions) |> Map.new()
    angles = Map.new(wheel_joints, fn {wheel, joint} -> {wheel, Map.get(by_name, joint)} end)
    if nil in Map.values(angles), do: nil, else: angles
  end
end
