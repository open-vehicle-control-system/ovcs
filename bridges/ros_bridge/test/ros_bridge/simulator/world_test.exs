defmodule RosBridge.Simulator.WorldTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.GeometryMsgs.Msg.Twist
  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.World
  alias SimulatorCore.Vehicle

  @world %{wheel_joints: ["left_wheel", "right_wheel"]}

  defp joint_states(positions) do
    joint_state = %JointState{
      name: ["steering", "left_wheel", "right_wheel"],
      position: positions
    }

    {:ros_message, {"joint_states", joint_state}}
  end

  test "reads the wheels' mean position in turns" do
    turns = World.wheel_turns(joint_states([0.3, 2 * :math.pi(), 6 * :math.pi()]), @world)

    assert_in_delta turns, 2.0, 1.0e-9
  end

  test "reads nothing when a wheel or its position is missing" do
    assert World.wheel_turns(joint_states([]), @world) == nil

    assert World.wheel_turns(joint_states([0.3, 1.0, 2.0]), %{wheel_joints: ["other_wheel"]}) ==
             nil
  end

  test "reads nothing from another ROS message" do
    message = {:ros_message, {"simulator/drive", %Twist{}}}

    assert World.wheel_turns(message, @world) == nil
  end

  test "drives at the commanded speed and its Ackermann yaw rate, positive to the left" do
    turning = %Vehicle{
      wheelbase_m: 0.3,
      wheel_radius_m: 0.05,
      commanded_speed_m_s: 1.0,
      steering_rad: 0.3
    }

    %Twist{linear: linear, angular: angular} = World.twist(turning)

    assert linear.x == 1.0
    assert_in_delta angular.z, :math.tan(0.3) / 0.3, 1.0e-9
  end
end
