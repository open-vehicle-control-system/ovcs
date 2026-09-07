defmodule RosBridge.Publishers.OdometryTest do
  @moduledoc """
  The dead-reckoning core, driven through `observe/2` and
  `publishable?/2` against stub states — `init/1` subscribes to CAN
  and registers on a driver, neither of which is under test.
  """
  use ExUnit.Case, async: true

  alias RosBridge.Publishers.Odometry
  alias RosBridge.Publishers.Odometry.State

  defp state(overrides) do
    struct!(
      %State{
        topic: "odom",
        odom_frame_id: "odom",
        base_frame_id: "base_link",
        publish_interval_ms: 50,
        stale_after_ms: 300
      },
      overrides
    )
  end

  defp sample(overrides) do
    Map.merge(
      %{speed: 1.0, steering_angle: 0.0, speed_valid: true, sequence: 2, at_ms: 1_000},
      overrides
    )
  end

  describe "observe/2" do
    test "a retransmission moves nothing" do
      before = state(sequence: 5, x: 3.0, speed_valid: true, yaw: 0.0, last_fresh_at_ms: 900)
      assert Odometry.observe(before, sample(%{sequence: 5, speed: 9.0})) == before
    end

    test "a fresh sample integrates the previous speed along the heading" do
      # Heading π/2: all the distance goes to y. 2 m/s for 100 ms.
      state =
        state(
          sequence: 1,
          speed: 2.0,
          speed_valid: true,
          yaw: :math.pi() / 2,
          last_fresh_at_ms: 900
        )

      after_state = Odometry.observe(state, sample(%{at_ms: 1_000}))

      assert_in_delta after_state.y, 0.2, 1.0e-9
      assert_in_delta after_state.x, 0.0, 1.0e-9
      assert after_state.sequence == 2
      assert after_state.speed == 1.0
    end

    test "a negative speed integrates backwards" do
      state = state(sequence: 1, speed: -1.0, speed_valid: true, yaw: 0.0, last_fresh_at_ms: 900)

      after_state = Odometry.observe(state, sample(%{at_ms: 1_000}))
      assert_in_delta after_state.x, -0.1, 1.0e-9
    end

    test "the first sample sets the clock without integrating" do
      after_state = Odometry.observe(state(speed_valid: true, yaw: 0.0), sample(%{}))

      assert after_state.x == 0.0
      assert after_state.last_fresh_at_ms == 1_000
    end

    test "a gap wider than the trust window is skipped, not integrated" do
      # 2 s of silence: the path across it is unknown. The position
      # holds; the clock and the sample still advance.
      state = state(sequence: 1, speed: 2.0, speed_valid: true, yaw: 0.0, last_fresh_at_ms: 0)

      after_state = Odometry.observe(state, sample(%{at_ms: 2_000}))

      assert after_state.x == 0.0
      assert after_state.last_fresh_at_ms == 2_000
    end

    test "an invalid speed does not integrate, in either direction" do
      was_invalid =
        state(sequence: 1, speed: 2.0, speed_valid: false, yaw: 0.0, last_fresh_at_ms: 900)

      assert Odometry.observe(was_invalid, sample(%{})).x == 0.0

      goes_invalid =
        state(sequence: 1, speed: 2.0, speed_valid: true, yaw: 0.0, last_fresh_at_ms: 900)

      assert Odometry.observe(goes_invalid, sample(%{speed_valid: false})).x == 0.0
    end

    test "no heading yet means no integration" do
      state = state(sequence: 1, speed: 2.0, speed_valid: true, yaw: nil, last_fresh_at_ms: 900)
      assert Odometry.observe(state, sample(%{})).x == 0.0
    end
  end

  describe "publishable?/2" do
    test "needs a valid speed, a heading, and a fresh frame" do
      good = state(speed_valid: true, yaw: 0.0, last_fresh_at_ms: 900)
      assert Odometry.publishable?(good, 1_000)

      refute Odometry.publishable?(
               state(speed_valid: false, yaw: 0.0, last_fresh_at_ms: 900),
               1_000
             )

      refute Odometry.publishable?(
               state(speed_valid: true, yaw: nil, last_fresh_at_ms: 900),
               1_000
             )

      refute Odometry.publishable?(state(speed_valid: true, yaw: 0.0), 1_000)
    end

    test "goes quiet when the frame stream stales" do
      state = state(speed_valid: true, yaw: 0.0, last_fresh_at_ms: 0)
      refute Odometry.publishable?(state, 301)
    end
  end

  describe "yaw_from_quaternion/4" do
    test "recovers the yaw from a pure z rotation" do
      yaw = 0.7
      z = :math.sin(yaw / 2)
      w = :math.cos(yaw / 2)
      assert_in_delta Odometry.yaw_from_quaternion(0.0, 0.0, z, w), yaw, 1.0e-9
    end

    test "is zero for identity" do
      assert Odometry.yaw_from_quaternion(0.0, 0.0, 0.0, 1.0) == 0.0
    end
  end
end
