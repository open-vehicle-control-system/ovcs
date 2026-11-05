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
        stale_after_ms: 300,
        yaw_at_ms: Keyword.get(overrides, :last_fresh_at_ms, 900),
        yaw_rate_at_ms: Keyword.get(overrides, :last_fresh_at_ms, 900),
        last_step_yaw: Keyword.get(overrides, :yaw)
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

  describe "diagonal/1" do
    test "puts the six variances on the diagonal of a row-major 6x6" do
      covariance = Odometry.diagonal([1, 2, 3, 4, 5, 6])

      assert length(covariance) == 36

      assert Enum.map([0, 7, 14, 21, 28, 35], &Enum.at(covariance, &1)) == [
               1.0,
               2.0,
               3.0,
               4.0,
               5.0,
               6.0
             ]

      assert covariance
             |> Enum.with_index()
             |> Enum.reject(fn {_, i} -> rem(i, 7) == 0 end)
             |> Enum.all?(fn {v, _} -> v == 0.0 end)
    end
  end

  describe "base_position/1" do
    test "is the integrated rear axle when base_link sits on it" do
      assert Odometry.base_position(state(x: 1.0, y: 2.0, yaw: 0.7)) == {1.0, 2.0}
    end

    test "is base_offset ahead of the rear axle along the heading" do
      {x, y} =
        Odometry.base_position(state(base_offset: 0.2, x: 1.0, y: 2.0, yaw: :math.pi() / 2))

      assert_in_delta x, 1.0, 1.0e-9
      assert_in_delta y, 2.2, 1.0e-9
    end

    test "ends a quarter turn half a wheelbase ahead of the rear axle" do
      # 1 m/s around a 1 m circle: the rear axle goes from the origin to
      # (1, 1) and ends heading +y, so base_link ends at (1, 1 + offset).
      steps = 2000
      step_ms = :math.pi() / 2 / steps * 1000

      start =
        state(
          base_offset: 0.162,
          speed: 1.0,
          speed_valid: true,
          yaw: 0.0,
          sequence: 0,
          last_fresh_at_ms: 0.0
        )

      final_state =
        Enum.reduce(1..steps, start, fn step, step_state ->
          step_state =
            Odometry.observe(step_state, sample(%{sequence: step, at_ms: step * step_ms}))

          %{
            step_state
            | yaw: step * step_ms / 1000,
              yaw_at_ms: step * step_ms,
              yaw_rate_at_ms: step * step_ms
          }
        end)

      {x, y} = Odometry.base_position(final_state)
      assert_in_delta x, 1.0, 0.01
      assert_in_delta y, 1.162, 0.01
    end
  end

  describe "a vehicle_motion frame" do
    test "whose validity flags the layout does not map leaves both readings invalid" do
      signals = %{
        "speed" => %Cantastic.Signal{value: Decimal.new("0.5")},
        "steering_angle" => %Cantastic.Signal{value: Decimal.new("0")},
        "speed_valid" => %Cantastic.Signal{value: nil},
        "distance" => %Cantastic.Signal{value: Decimal.new("1.0")},
        "distance_valid" => %Cantastic.Signal{value: nil},
        "sequence" => %Cantastic.Signal{value: 3}
      }

      frame = %Cantastic.Frame{name: "vehicle_motion", signals: signals}
      {:noreply, state} = Odometry.handle_info({:handle_frame, frame}, state(speed_valid: true))

      refute state.speed_valid
      refute state.distance_valid
      refute Odometry.publishable?(state, state.last_fresh_at_ms || 0)
    end
  end

  describe "observe/2 with a distance counter" do
    defp moving(overrides) do
      state(
        Keyword.merge(
          [
            sequence: 1,
            speed: 2.0,
            speed_valid: true,
            yaw: 0.0,
            last_fresh_at_ms: 900,
            distance: 10.0,
            distance_valid: true
          ],
          overrides
        )
      )
    end

    test "integrates the counter's difference, not the speed" do
      after_state = Odometry.observe(moving([]), sample(%{distance: 10.03, distance_valid: true}))
      assert_in_delta after_state.x, 0.03, 1.0e-9
    end

    test "a counter that wrapped still steps forward" do
      after_state =
        Odometry.observe(moving(distance: 65.52), sample(%{distance: 0.01, distance_valid: true}))

      assert_in_delta after_state.x, 0.026, 1.0e-9
    end

    test "reversing steps backwards" do
      after_state = Odometry.observe(moving([]), sample(%{distance: 9.98, distance_valid: true}))
      assert_in_delta after_state.x, -0.02, 1.0e-9
    end

    test "a restarted counter is skipped, not integrated" do
      after_state = Odometry.observe(moving([]), sample(%{distance: 42.0, distance_valid: true}))
      assert after_state.x == 0.0
      assert after_state.distance == 42.0
    end

    test "without a valid counter it falls back to the speed" do
      after_state =
        Odometry.observe(
          moving(distance_valid: false),
          sample(%{distance: 10.03, distance_valid: true})
        )

      assert_in_delta after_state.x, 0.2, 1.0e-9
    end
  end

  describe "publishable?/2" do
    test "needs a valid speed, a heading, and a fresh frame" do
      publishable_state = state(speed_valid: true, yaw: 0.0, last_fresh_at_ms: 900)
      assert Odometry.publishable?(publishable_state, 1_000)

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

  # Only this module touches the publisher's named table, and its tests run one at a time.
  describe "publishing?/1" do
    test "is true where no odometry publisher runs" do
      assert Odometry.publishing?(1_000)
    end

    test "is false until odom has been published" do
      Odometry.open_record()
      refute Odometry.publishing?(1_000)
    end

    test "the velocity gate expires at the oldest IMU stream's deadline" do
      alias RosBridge.Consumers.Velocity
      gate = %Velocity.State{require_odometry: true}
      refute Velocity.commands_allowed?(gate, 1000)
      Odometry.open_record()
      Odometry.record_published(state(yaw_at_ms: 1000, yaw_rate_at_ms: 850), 1000)
      assert Velocity.commands_allowed?(gate, 1050)
      refute Velocity.commands_allowed?(gate, 1051)
      assert Velocity.commands_allowed?(%Velocity.State{}, 1051)
    end

    test "is true within stale_after_ms of the last publish, false after it" do
      Odometry.open_record()

      Odometry.record_published(
        state(
          stale_after_ms: 300,
          imu_stale_after_ms: 300,
          yaw_at_ms: 1000,
          yaw_rate_at_ms: 1000
        ),
        1_000
      )

      assert Odometry.publishing?(1_300)
      refute Odometry.publishing?(1_301)
    end
  end

  describe "IMU validity" do
    alias OvcsDrivers.Imu.Sample

    defp rotation(reference, at_ms, yaw \\ 0.0, accuracy \\ 3) do
      %Sample{
        kind: :rotation,
        x: 0.0,
        y: 0.0,
        z: :math.sin(yaw / 2),
        w: :math.cos(yaw / 2),
        reference: reference,
        captured_at_ns: at_ms * 1_000_000,
        accuracy: accuracy
      }
    end

    test "heading and gyro expire independently while motion remains fresh" do
      ready =
        state(
          speed_valid: true,
          yaw: 0.0,
          last_fresh_at_ms: 1000,
          yaw_at_ms: 1000,
          yaw_rate_at_ms: 1000
        )

      assert Odometry.publishable?(ready, 1000)
      refute Odometry.publishable?(%{ready | yaw_at_ms: 799}, 1000)
      refute Odometry.publishable?(%{ready | yaw_rate_at_ms: 799}, 1000)
      assert Odometry.observe(%{ready | yaw_at_ms: 700}, sample(%{at_ms: 1100})).x == 0.0
    end

    test "stale or low-accuracy samples cannot initialize the heading" do
      state = state(minimum_imu_accuracy: 1, yaw_at_ms: nil)
      reference = make_ref()
      state = Odometry.observe_imu(state, rotation(reference, 100, 1.0, 0), 100_000_000)
      assert state.yaw_offset == nil
      state = Odometry.observe_imu(state, rotation(reference, 100, 1.0), 500_000_000)
      assert state.yaw_offset == nil
      state = Odometry.observe_imu(state, rotation(reference, 500, 1.0), 500_000_000)
      assert_in_delta state.yaw_offset, 1.0, 1.0e-9
    end

    test "out-of-order samples cannot rewind heading" do
      reference = make_ref()
      state = state(yaw_at_ms: nil)
      state = Odometry.observe_imu(state, rotation(reference, 500), 500_000_000)
      state = Odometry.observe_imu(state, rotation(reference, 600, 0.2), 600_000_000)
      assert Odometry.observe_imu(state, rotation(reference, 550, 1.0), 600_000_000) == state
    end

    test "a reset latches odometry off instead of splicing two heading references" do
      state = state(yaw_at_ms: nil, speed_valid: true, last_fresh_at_ms: 600, yaw_rate_at_ms: 600)
      state = Odometry.observe_imu(state, rotation(make_ref(), 500), 500_000_000)
      state = Odometry.observe_imu(state, rotation(make_ref(), 600), 600_000_000)
      assert state.imu_reset
      refute Odometry.publishable?(state, 600)
      assert Odometry.observe(state, sample(%{at_ms: 700})).x == 0.0
    end

    test "invalid flags on a repeated CAN sequence revoke validity" do
      state = state(sequence: 2, speed_valid: true, yaw: 0.0)
      refute Odometry.observe(state, sample(%{speed_valid: false})).speed_valid
    end
  end

  test "a finite quarter circle integrates its arc, including backwards" do
    {dx, dy} = Odometry.arc_step(:math.pi() / 2, 0.0, :math.pi() / 2)
    assert_in_delta dx, 1.0, 1.0e-9
    assert_in_delta dy, 1.0, 1.0e-9
    {dx, dy} = Odometry.arc_step(-:math.pi() / 2, 0.0, :math.pi() / 2)
    assert_in_delta dx, -1.0, 1.0e-9
    assert_in_delta dy, -1.0, 1.0e-9
  end

  test "heading wrap uses the short turn through pi" do
    {dx, dy} = Odometry.arc_step(0.2, :math.pi() - 0.1, -:math.pi() + 0.1)
    assert_in_delta dx, -2 * :math.sin(0.1), 1.0e-9
    assert_in_delta dy, 0.0, 1.0e-9
  end

  test "rear-axle odometry and a forward TF base describe the same rigid body" do
    state =
      state(
        base_frame_id: "rear_axle",
        tf_frame_id: "base_link",
        base_offset: 0.0,
        tf_base_offset: 0.162,
        x: 1.0,
        y: 2.0,
        yaw: :math.pi() / 2,
        yaw_rate: 1.0,
        speed: 0.5,
        last_fresh_at_ms: System.monotonic_time(:millisecond)
      )

    {odometry, transform} = Odometry.messages(state)
    assert odometry.child_frame_id == "rear_axle"
    assert odometry.pose.pose.position.x == 1.0
    assert odometry.pose.pose.position.y == 2.0
    assert odometry.twist.twist.linear.y == 0.0
    assert transform.child_frame_id == "base_link"
    assert_in_delta transform.transform.translation.x, 1.0, 1.0e-9
    assert_in_delta transform.transform.translation.y, 2.162, 1.0e-9
    assert odometry.header.stamp == transform.header.stamp
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
