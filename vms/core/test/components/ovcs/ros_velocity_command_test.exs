defmodule VmsCore.Components.OVCS.RosVelocityCommandTest do
  @moduledoc """
  Tests for the velocity-to-drivetrain conversion.

  This is the arithmetic that decides where a planner's command
  actually points the wheels. The first thing asserted is that zero
  means zero: a normalisation of the form `(angle - max) / range` maps
  straight ahead to half lock, and a vehicle built on that drives in a
  circle when told to go straight.

  Driven through `handle_info/2` against a stub state: `init/1`
  subscribes to Cantastic, which does not exist under
  `mix test --no-start`.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.RosCommand.Freshness
  alias VmsCore.Components.OVCS.RosVelocityCommand, as: Velocity

  # OVCS Mini, from `OvcsMini.geometry/0`. min_turning_radius = 0.5659 m.
  @geometry %{wheelbase: 0.324, steering_limit: 0.52}
  @max_speed 5.0

  defp fresh_freshness do
    now = System.monotonic_time(:millisecond)
    %{Freshness.new(300, now) | sequence: 0, fresh_at: now, stale: false}
  end

  defp expired_freshness do
    now = System.monotonic_time(:millisecond)
    %{Freshness.new(300, now - 10_000) | sequence: 0, fresh_at: now - 10_000, stale: false}
  end

  defp stub_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        geometry: @geometry,
        max_speed: @max_speed,
        steering_sign: 1,
        freshness: fresh_freshness(),
        linear: D.new(0),
        angular: D.new(0),
        requested_steering: D.new(0),
        requested_throttle: D.new(0)
      },
      overrides
    )
  end

  defp frame(linear, angular, sequence \\ 1) do
    {:handle_frame,
     %Frame{
       name: "ros_velocity_command",
       signals: %{
         "linear" => %Signal{name: "linear", value: D.from_float(linear)},
         "angular" => %Signal{name: "angular", value: D.from_float(angular)},
         "sequence" => %Signal{name: "sequence", value: sequence}
       }
     }}
  end

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  # What the component would put on the bus on its next tick.
  defp commanded(state) do
    {:noreply, _state} = Velocity.handle_info(:loop, state)
    assert_receive %Message{name: :requested_steering, value: steering, source: Velocity}
    assert_receive %Message{name: :requested_throttle, value: throttle, source: Velocity}
    {D.to_float(steering), D.to_float(throttle)}
  end

  defp drive(linear, angular, overrides \\ %{}) do
    {:noreply, state} = Velocity.handle_info(frame(linear, angular), stub_state(overrides))
    commanded(state)
  end

  describe "straight ahead" do
    test "zero yaw rate means zero steering" do
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
      # atan(0.324 * 0.5 / 1.0) / 0.52
      {steering, _} = drive(1.0, 0.5)
      assert_in_delta steering, 0.308855, 1.0e-5
    end

    test "halving the yaw rate for a given speed roughly halves the angle" do
      {steering, _} = drive(2.0, 0.5)
      assert_in_delta steering, 0.155430, 1.0e-5
    end

    test "the sign follows the yaw rate" do
      {left, _} = drive(1.0, 0.5)
      {right, _} = drive(1.0, -0.5)
      assert left > 0 and right < 0
      assert_in_delta left, -right, 1.0e-9
    end

    test "a tighter arc needs more lock" do
      {gentle, _} = drive(1.0, 0.5)
      {tight, _} = drive(1.0, 1.5)
      assert tight > gentle
    end
  end

  describe "the steering sign" do
    test "is applied after the kinematics, so only the direction changes" do
      {steering, _} = drive(1.0, 0.5, %{steering_sign: -1})
      assert_in_delta steering, -0.308855, 1.0e-5
    end
  end

  describe "commands the vehicle cannot execute" do
    test "an arc tighter than the minimum radius is clamped, not refused" do
      {steering, _} = drive(1.0, 5.0)
      assert_in_delta steering, 1.0, 1.0e-6
    end

    test "steering never leaves [-1, 1] whatever is commanded" do
      for linear <- [-3.0, -0.5, 0.1, 2.0, 10.0], angular <- [-20.0, -1.0, 0.3, 4.0, 50.0] do
        {steering, _} = drive(linear, angular)

        assert steering >= -1.0 and steering <= 1.0,
               "v=#{linear} omega=#{angular} produced #{steering}"
      end
    end

    test "rotating on the spot becomes standing still with the wheels straight" do
      {steering, throttle} = drive(0.0, 2.0)
      assert_in_delta steering, 0.0, 1.0e-9
      assert_in_delta throttle, 0.0, 1.0e-9
    end

    test "below the wire resolution the vehicle is stopped" do
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

  describe "when the sequence stops changing" do
    test "the velocity is zeroed" do
      moving = stub_state(%{linear: D.from_float(2.0), angular: D.from_float(0.5)})
      {steering, throttle} = commanded(moving)
      assert throttle > 0.0 and steering > 0.0

      expired = %{moving | freshness: expired_freshness()}
      assert {0.0, 0.0} = commanded(expired)
    end

    test "a retransmitted frame is not applied as fresh input" do
      state = stub_state(%{linear: D.from_float(2.0)})
      # Same sequence as the tracker already holds.
      {:noreply, state} = Velocity.handle_info(frame(1.0, 0.0, 0), state)
      assert D.eq?(state.linear, D.from_float(2.0))
    end

    test "a later sample restores control with no latch to clear" do
      expired = stub_state(%{linear: D.from_float(2.0), freshness: expired_freshness()})
      {_, zeroed} = commanded(expired)
      assert zeroed == 0.0

      {:noreply, recovered} = Velocity.handle_info(frame(1.0, 0.0, 1), expired)
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
