defmodule RosBridge.Simulator.PlantTest do
  use ExUnit.Case, async: true

  alias Ros2.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.Plant

  @wheels ["left_wheel", "right_wheel"]

  defp joint_state(velocities),
    do: %JointState{name: ["steering", "left_wheel", "right_wheel"], velocity: velocities}

  test "measures the wheels' mean angular velocity times their radius" do
    assert Plant.wheel_speed(joint_state([0.3, 10.0, 12.0]), @wheels, 0.05) == 0.55
  end

  test "measures nothing when a wheel or its velocity is missing" do
    assert Plant.wheel_speed(joint_state([]), @wheels, 0.05) == nil
    assert Plant.wheel_speed(joint_state([0.3, 10.0, 12.0]), ["other_wheel"], 0.05) == nil
  end
end
