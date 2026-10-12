defmodule RosBridge.Simulator.HardwareTest do
  use ExUnit.Case, async: true

  alias Ros2.SensorMsgs.Msg.JointState
  alias RosBridge.Simulator.Hardware

  @wheels ["left_wheel", "right_wheel"]

  defp joint_state(positions),
    do: %JointState{name: ["steering", "left_wheel", "right_wheel"], position: positions}

  test "reads the wheels' mean position in turns" do
    assert_in_delta Hardware.wheel_turns(
                      joint_state([0.3, 2 * :math.pi(), 6 * :math.pi()]),
                      @wheels
                    ),
                    2.0,
                    1.0e-9
  end

  test "the wheels' turn since the last tick: none before a sample, zero for the first" do
    assert Hardware.wheel_turns_step(nil, nil) == nil
    assert Hardware.wheel_turns_step(4.25, nil) == 0.0
    assert Hardware.wheel_turns_step(4.25, 4.0) == 0.25
  end

  test "reads nothing when a wheel or its position is missing" do
    assert Hardware.wheel_turns(joint_state([]), @wheels) == nil
    assert Hardware.wheel_turns(joint_state([0.3, 1.0, 2.0]), ["other_wheel"]) == nil
  end
end
