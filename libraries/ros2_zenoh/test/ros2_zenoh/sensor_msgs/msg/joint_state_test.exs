defmodule Ros2Zenoh.SensorMsgs.Msg.JointStateTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.RmwZenoh
  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias Ros2Zenoh.StdMsgs.Msg.Header

  test "round-trips through encode → decode_payload → parse" do
    # Names of uneven lengths, so a misaligned float64 run shows.
    joint_state = %JointState{
      header: %Header{stamp: %Time{sec: 3, nanosec: 400}, frame_id: ""},
      name: ["front_left_wheel_joint", "rear_left_wheel_joint", "a"],
      position: [0.5, -1.25, 2.0],
      velocity: [10.5, 10.25, -0.125],
      effort: []
    }

    {:ok, body} = RmwZenoh.decode_payload(RmwZenoh.encode_payload(joint_state))
    assert {:ok, ^joint_state, ""} = JointState.parse(body)
  end
end
