defmodule RosBridge.Simulator.WorldTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.GeometryMsgs.Msg.Twist
  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.World
  alias SimulatorCore.{Efforts, FlatGround}

  @vehicle %{wheelbase_m: 0.3, wheel_radius_m: 0.05, mass_kg: 2.41}
  @wheel_joints %{
    front_left: "front_left_wheel",
    front_right: "front_right_wheel",
    rear_left: "rear_left_wheel",
    rear_right: "rear_right_wheel"
  }

  # The world's state without subscribing: what `init/1` builds, on a clock the test sets.
  defp world(now_ms),
    do: %{
      wheel_joints: @wheel_joints,
      ground: FlatGround.new(@vehicle),
      wheel_radius_m: @vehicle.wheel_radius_m,
      start: nil,
      previous: nil,
      clock: fn -> now_ms end
    }

  defp joint_states(position) do
    names = ["steering" | Map.values(@wheel_joints)]
    joint_state = %JointState{name: names, position: [0.3 | List.duplicate(position, 4)]}
    {:ros_message, {"joint_states", joint_state}}
  end

  test "reads each wheel's angle from its first message, and its spin from the change since the last" do
    {_first, world} = World.world_state(joint_states(1.0), world(0))
    {state, _world} = World.world_state(joint_states(2.0), %{world | clock: fn -> 500 end})

    for wheel <- Map.keys(@wheel_joints) do
      assert state.wheels[wheel] == %{angle_rad: 1.0, omega_rad_s: 2.0, in_contact: true}
    end

    assert state.wheel_radius_m == 0.05
  end

  test "a first message far along the joints reads as the wheels' start" do
    {state, _world} = World.world_state(joint_states(400.0), world(0))

    assert state.wheels[:front_left].angle_rad == 0.0
  end

  test "skips a message in the same millisecond as the previous one" do
    {_first, world} = World.world_state(joint_states(1.0), world(0))

    assert World.world_state(joint_states(1.5), world) == nil
  end

  test "a first message reads the wheels still" do
    {state, _world} = World.world_state(joint_states(1.0), world(0))

    assert state.wheels[:front_left].omega_rad_s == 0.0
  end

  test "reads nothing when a wheel is missing" do
    joint_state = %JointState{name: ["front_left_wheel"], position: [1.0]}

    assert World.world_state({:ros_message, {"joint_states", joint_state}}, world(0)) == nil
  end

  test "reads nothing from another ROS message" do
    assert World.world_state({:ros_message, {"simulator/drive", %Twist{}}}, world(0)) == nil
  end

  test "the efforts move the speed it drives Gazebo at" do
    stepped = World.step(world(0), %Efforts{drive_torque_nm: 1.0}, 0.1)

    assert %Twist{linear: %{x: speed}} = World.twist(stepped.ground)
    assert speed > 0.0
  end

  test "against a wall, its speed leads the wheels Gazebo measures by at most 0.25 m/s" do
    pushing = %{world(0) | ground: %{FlatGround.new(@vehicle) | speed_m_s: 3.0}}
    {_first, pushing} = World.world_state(joint_states(1.0), pushing)

    {_state, held} = World.world_state(joint_states(1.0), %{pushing | clock: fn -> 500 end})

    assert_in_delta held.ground.speed_m_s, 0.25, 1.0e-12
  end

  test "in reverse against a wall, its speed leads the wheels by at most 0.25 m/s backwards" do
    pushing = %{world(0) | ground: %{FlatGround.new(@vehicle) | speed_m_s: -3.0}}

    {_state, held} = World.world_state(joint_states(1.0), pushing)

    assert_in_delta held.ground.speed_m_s, -0.25, 1.0e-12
  end

  test "drives at its speed and the Ackermann yaw rate, positive to the left" do
    turning = %{FlatGround.new(@vehicle) | speed_m_s: 1.0, steering_rad: 0.3}

    %Twist{linear: linear, angular: angular} = World.twist(turning)

    assert linear.x == 1.0
    assert_in_delta angular.z, :math.tan(0.3) / 0.3, 1.0e-9
  end
end
