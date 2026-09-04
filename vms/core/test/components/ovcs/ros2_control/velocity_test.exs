defmodule VmsCore.Components.OVCS.Ros2Control.VelocityTest do
  @moduledoc """
  Tests for the velocity-to-drivetrain conversion.

  This is the arithmetic that decides where a planner's command
  actually points the wheels, and the prototype it replaces got it
  wrong in a way that would have been invisible on a bench: it
  computed `(angle - max_angle) / range`, which maps a straight-ahead
  command to **-0.5** — half lock — rather than to zero. A vehicle
  built on that drives in a circle when told to go straight.

  So the first thing asserted is that zero means zero.

  Driven through `handle_info/2` against a stub state, the way
  `VmsCore.Managers.GearTest` does: `init/1` subscribes to Cantastic
  and enables a frame watcher, neither of which exists under
  `mix test --no-start`, and neither is what is under test.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.Ros2Control.Velocity

  # OVCS Mini, from `OvcsMini.geometry/0`. min_turning_radius = 0.5659 m.
  @geometry %{wheelbase: 0.324, steering_limit: 0.52}
  @max_speed 5.0

  defp stub_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        geometry: @geometry,
        max_speed: @max_speed,
        linear: D.new(0),
        angular: D.new(0),
        requested_steering: D.new(0),
        requested_throttle: D.new(0)
      },
      overrides
    )
  end

  defp frame(linear, angular) do
    {:handle_frame,
     %Frame{
       name: "ros2_control",
       signals: %{
         "linear" => %Signal{name: "linear", value: D.from_float(linear)},
         "angular" => %Signal{name: "angular", value: D.from_float(angular)}
       }
     }}
  end

  # What the component would put on the bus on its next tick.
  defp commanded(state) do
    OvcsBus.subscribe("messages")
    {:noreply, _state} = Velocity.handle_info(:loop, state)
    assert_receive %Message{name: :requested_steering, value: steering, source: Velocity}
    assert_receive %Message{name: :requested_throttle, value: throttle, source: Velocity}
    {D.to_float(steering), D.to_float(throttle)}
  end

  defp drive(linear, angular) do
    {:noreply, state} = Velocity.handle_info(frame(linear, angular), stub_state())
    commanded(state)
  end

  describe "straight ahead" do
    test "zero yaw rate means zero steering" do
      # The regression the prototype would fail: it answered -0.5 here.
      {steering, throttle} = drive(1.0, 0.0)
      assert_in_delta steering, 0.0, 1.0e-9
      assert_in_delta throttle, 0.2, 1.0e-6
    end

    test "reverse is a negative throttle, not a mode" do
      {steering, throttle} = drive(-1.0, 0.0)
      assert_in_delta steering, 0.0, 1.0e-9
      assert_in_delta throttle, -0.2, 1.0e-6
    end
  end

  describe "turning" do
    test "the steering angle follows atan(wheelbase * omega / v)" do
      # 1 m/s at 0.5 rad/s is a 2 m arc, comfortably outside the
      # 0.566 m minimum, so nothing clamps and the raw geometry shows.
      #   atan(0.324 * 0.5 / 1.0) = atan(0.1620) = 0.160605 rad
      #   0.160605 / 0.52 = 0.308855
      {steering, _} = drive(1.0, 0.5)
      assert_in_delta steering, 0.308855, 1.0e-5
    end

    test "halving the yaw rate for a given speed roughly halves the angle" do
      # Not exactly halved — atan is not linear — but close at these
      # angles, and a sign that the wheelbase is in the numerator
      # rather than inverted.
      #   v=2.0 omega=0.5 -> atan(0.0810) = 0.080824 -> 0.155430
      {steering, _} = drive(2.0, 0.5)
      assert_in_delta steering, 0.155430, 1.0e-5
    end

    test "the sign follows the yaw rate" do
      {left, _} = drive(1.0, 0.5)
      {right, _} = drive(1.0, -0.5)
      assert_in_delta left, -right, 1.0e-9
      assert left > 0, "counter-clockwise should steer positive, per REP-103"
    end

    test "a tighter arc needs more lock" do
      {gentle, _} = drive(2.0, 0.5)
      {tight, _} = drive(1.0, 0.5)
      assert tight > gentle
    end
  end

  describe "commands the vehicle cannot execute" do
    test "an arc tighter than the minimum radius is clamped, not refused" do
      # At 1 m/s the achievable rate is 1/0.5659 = 1.767 rad/s. Ask for
      # 5 and the result must be full lock, never beyond it.
      {steering, _} = drive(1.0, 5.0)
      assert_in_delta steering, 1.0, 1.0e-6
    end

    test "steering never leaves [-1, 1] whatever is commanded" do
      for angular <- [-100.0, -5.0, 5.0, 100.0], linear <- [0.2, 1.0, 5.0] do
        {steering, _} = drive(linear, angular)

        assert steering >= -1.0 and steering <= 1.0,
               "v=#{linear} omega=#{angular} produced #{steering}"
      end
    end

    test "rotating on the spot becomes standing still with the wheels straight" do
      # The clamp does this without a special case: the achievable yaw
      # rate at zero speed is zero, so the requested angle is zero.
      {steering, throttle} = drive(0.0, 2.0)
      assert_in_delta steering, 0.0, 1.0e-9
      assert_in_delta throttle, 0.0, 1.0e-9
    end

    test "a negligible speed does not synthesise steering out of noise" do
      # 1e-9 m/s would divide near-zero and produce an angle from
      # rounding. Below the wire resolution the vehicle is stopped.
      {steering, _} = drive(1.0e-9, 1.0)
      assert_in_delta steering, 0.0, 1.0e-9
    end

    test "throttle saturates rather than exceeding full scale" do
      {_, fast} = drive(50.0, 0.0)
      {_, reverse} = drive(-50.0, 0.0)
      assert_in_delta fast, 1.0, 1.0e-9
      assert_in_delta reverse, -1.0, 1.0e-9
    end
  end

  describe "when the frame stops arriving" do
    test "the velocity is zeroed" do
      {:noreply, moving} = Velocity.handle_info(frame(2.0, 0.5), stub_state())
      {steering, throttle} = commanded(moving)
      assert throttle > 0.0 and steering > 0.0

      {:noreply, expired} =
        Velocity.handle_info({:handle_missing_frame, :ovcs, "ros2_control"}, moving)

      assert {0.0, 0.0} = commanded(expired)
    end

    test "a later frame restores control with no latch to clear" do
      {:noreply, expired} =
        Velocity.handle_info(
          {:handle_missing_frame, :ovcs, "ros2_control"},
          stub_state(%{linear: D.from_float(2.0)})
        )

      {:noreply, recovered} = Velocity.handle_info(frame(1.0, 0.0), expired)
      {_, throttle} = commanded(recovered)
      assert_in_delta throttle, 0.2, 1.0e-6
    end

    test "an unexpected message is ignored rather than fatal" do
      state = stub_state(%{linear: D.from_float(1.0)})

      for message <- [
            {:handle_missing_frame, :ovcs, "some_other_frame"},
            {:DOWN, make_ref(), :process, self(), :normal},
            :unplanned
          ] do
        assert {:noreply, ^state} = Velocity.handle_info(message, state)
      end
    end
  end
end
