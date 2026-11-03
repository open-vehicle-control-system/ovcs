defmodule RosBridge.Publishers.AckermannJointStatesTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.SensorMsgs.Msg.JointState
  alias RosBridge.Publishers.AckermannJointStates
  alias RosBridge.Publishers.AckermannJointStates.State

  doctest AckermannJointStates
  doctest RosBridge.VehicleMotion

  @wheelbase 0.324
  @kingpin_width 0.296

  defp state(overrides) do
    struct!(
      %State{
        topic: "joint_states",
        steering_joints: {"front_left_steering_joint", "front_right_steering_joint"},
        wheel_joints: ["front_left_wheel_joint", "rear_left_wheel_joint"],
        wheelbase: @wheelbase,
        kingpin_width: @kingpin_width,
        wheel_radius: 0.05
      },
      overrides
    )
  end

  describe "wheel_steering_angles/3" do
    test "turning left, the left wheel is inside and turns more" do
      {left, right} = AckermannJointStates.wheel_steering_angles(0.3, @wheelbase, @kingpin_width)
      assert left > 0.3 and 0.3 > right and right > 0.0
    end

    test "both wheels turn about one centre on the rear axle's line" do
      for steering <- [-0.52, -0.1, 0.2, 0.52] do
        {left, right} =
          AckermannJointStates.wheel_steering_angles(steering, @wheelbase, @kingpin_width)

        radius = @wheelbase / :math.tan(steering)
        assert_in_delta @wheelbase / :math.tan(left), radius - @kingpin_width / 2, 1.0e-9
        assert_in_delta @wheelbase / :math.tan(right), radius + @kingpin_width / 2, 1.0e-9
      end
    end

    test "turning right mirrors turning left" do
      {left, right} = AckermannJointStates.wheel_steering_angles(0.4, @wheelbase, @kingpin_width)

      {mirrored_left, mirrored_right} =
        AckermannJointStates.wheel_steering_angles(-0.4, @wheelbase, @kingpin_width)

      assert_in_delta mirrored_left, -right, 1.0e-12
      assert_in_delta mirrored_right, -left, 1.0e-12
    end
  end

  describe "observe/2" do
    test "the wheels turn by the distance rolled over their radius" do
      after_state =
        state(sequence: 1, distance: 1.0)
        |> AckermannJointStates.observe(%{sequence: 2, distance: 1.1, steering_angle: 0.2})

      assert_in_delta after_state.wheel_angle, 2.0, 1.0e-9
      assert after_state.steering_angle == 0.2
    end

    test "across the counter's wrap, forward stays forward" do
      after_state =
        state(sequence: 1, distance: 65.53)
        |> AckermannJointStates.observe(%{sequence: 2, distance: 0.004, steering_angle: 0.0})

      assert_in_delta after_state.wheel_angle, 0.01 / 0.05, 1.0e-6
    end

    test "an invalid distance holds the wheels still" do
      after_state =
        state(sequence: 1, distance: 1.0, wheel_angle: 3.0)
        |> AckermannJointStates.observe(%{sequence: 2, distance: nil, steering_angle: 0.0})
        |> AckermannJointStates.observe(%{sequence: 3, distance: 1.2, steering_angle: 0.0})

      assert after_state.wheel_angle == 3.0
    end

    test "a retransmission changes nothing" do
      before = state(sequence: 4, distance: 1.0)

      assert AckermannJointStates.observe(before, %{
               sequence: 4,
               distance: 1.3,
               steering_angle: 0.5
             }) ==
               before
    end
  end

  test "names the steered wheels, then every wheel" do
    %JointState{name: name, position: [left, right | wheels]} =
      AckermannJointStates.joint_state(state(steering_angle: 0.0, wheel_angle: 1.5), %{
        sec: 0,
        nanosec: 0
      })

    assert name == [
             "front_left_steering_joint",
             "front_right_steering_joint",
             "front_left_wheel_joint",
             "rear_left_wheel_joint"
           ]

    assert {left, right, wheels} == {0.0, 0.0, [1.5, 1.5]}
  end
end
