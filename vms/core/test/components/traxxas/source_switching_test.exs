defmodule VmsCore.Components.Traxxas.SourceSwitchingTest do
  @moduledoc """
  The drivetrain follows whichever commander `Managers.ControlLevel`
  names, and stops propelling when it names none.

  That second half is the reason this file exists. The manager selects
  sources per control level, and a level with no commander — `:manual`
  on OVCS Mini, which has no pedals — selects `nil`. The message
  handler for `:requested_throttle` gates on the source, so with no
  source **no message matches and the last request persists**. Left
  alone, switching the transmitter to the safe position would leave
  the vehicle driving at whatever it was last told.

  Same family as the stale-CAN-frame hazard: the value is held rather
  than expired, and nothing about the held value announces itself.

  Driven through `handle_info/2` against a stub state, the way
  `VmsCore.Managers.GearTest` does — `init/1` subscribes to the bus
  and starts a timer, neither of which is under test.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Traxxas.{Steering, Throttle}

  @manager ControlLevelManager
  @commander SomeRosCommander
  @planner PlannerVelocity

  # `set_external_pwm/5` is a `GenServer.call` on whatever the actuator
  # was given as its controller, so a process that answers it is enough
  # to observe what actually reaches the ESC.
  defmodule FakeController do
    @moduledoc false
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:set_external_pwm, id, enabled, duty_cycle, frequency}, _from, test) do
      send(test, {:pwm, id, enabled, duty_cycle, frequency})
      {:reply, :ok, test}
    end
  end

  defp steering_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        controller: nil,
        external_pwm_id: 0,
        selected_control_level_source: @manager,
        requested_steering_source: @commander,
        requested_steering: D.new("0.7"),
        steering: D.new(0)
      },
      overrides
    )
  end

  defp throttle_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        controller: nil,
        external_pwm_id: 1,
        selected_control_level_source: @manager,
        requested_throttle_source: @commander,
        linear_sources: [],
        curve: Throttle.curve(%{}),
        requested_throttle: D.new("0.6"),
        throttle: D.new(0)
      },
      overrides
    )
  end

  defp source_message(name, value, source), do: %Message{name: name, value: value, source: source}

  describe "a level that commands nothing" do
    test "sends neutral on the first tick even before a commander is selected" do
      {:ok, controller} = FakeController.start_link(self())
      OvcsBus.subscribe("messages")

      {:ok, state} =
        Throttle.init(%{
          controller: controller,
          external_pwm_id: 1,
          selected_control_level_source: @manager
        })

      {:ok, :cancel} = :timer.cancel(state.loop_timer)
      {:noreply, state} = Throttle.handle_info(:loop, state)

      assert_received {:pwm, 1, true, duty, 100}
      assert D.eq?(duty, D.new("0.15"))
      assert_received %Message{name: :pulse_width_us, value: pulse, source: Throttle}
      assert D.eq?(pulse, D.new(1500))

      {:noreply, _state} = Throttle.handle_info(:loop, state)
      refute_received {:pwm, _, _, _, _}
    end

    test "zeroes the throttle rather than holding it" do
      # The dangerous case: driving at 0.6, switched to a level with no
      # commander. Holding would keep the vehicle moving.
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, nil, @manager),
          throttle_state()
        )

      assert D.equal?(state.requested_throttle, D.new(0)),
             "the last throttle survived a switch to a level with no commander"

      assert state.requested_throttle_source == nil
    end

    test "holds the steering, so the wheels stay where they are" do
      # Snapping the wheels straight mid-corner is a hazard, not a
      # mitigation. Only propulsion is removed.
      {:noreply, state} =
        Steering.handle_info(
          source_message(:requested_steering_source, nil, @manager),
          steering_state()
        )

      assert D.equal?(state.requested_steering, D.new("0.7"))
      assert state.requested_steering_source == nil
    end
  end

  describe "switching between commanders" do
    test "the new source is adopted and the current request is kept" do
      # Not a safety transition — one commander handing to another —
      # so the vehicle should not lurch to zero mid-handover. The next
      # message from the new source overwrites it anyway.
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      assert state.requested_throttle_source == AnotherCommander
      assert D.equal?(state.requested_throttle, D.new("0.6"))
    end

    test "a request from the newly selected source is accepted" do
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle, D.new("0.25"), AnotherCommander),
          state
        )

      assert D.equal?(state.requested_throttle, D.new("0.25"))
    end

    test "a request from the source that was just replaced is ignored" do
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle, D.new("1.0"), @commander),
          state
        )

      refute D.equal?(state.requested_throttle, D.new("1.0")),
             "a commander that lost the selection still moved the vehicle"
    end
  end

  describe "source authority" do
    test "only the configured manager can change the source" do
      # Anything else naming a source is either a misconfiguration or
      # something impersonating the manager. Either way it must not be
      # able to hand itself the vehicle.
      state = throttle_state()

      {:noreply, unchanged} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, Impostor, NotTheManager),
          state
        )

      assert unchanged.requested_throttle_source == @commander
    end
  end

  describe "the feel curve" do
    test "a switch between a shaped and a linear source still reaches the ESC" do
      # The request does not move, only the shaping does, so a cache
      # keyed on the request would hold the ESC at the previous curve.
      {:ok, controller} = FakeController.start_link(self())

      state =
        throttle_state(%{
          controller: controller,
          linear_sources: [@planner],
          requested_throttle: D.new("0.4")
        })

      {:noreply, state} = Throttle.handle_info(:loop, state)
      assert_received {:pwm, _id, _enabled, shaped_duty_cycle, _frequency}

      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, @planner, @manager),
          state
        )

      {:noreply, _state} = Throttle.handle_info(:loop, state)
      assert_received {:pwm, _id, _enabled, linear_duty_cycle, _frequency}

      refute D.eq?(shaped_duty_cycle, linear_duty_cycle),
             "the ESC stayed on the previous source's shaping"
    end

    test "with no curve configured a joystick request is squared, keeping its sign" do
      curve = Throttle.curve(%{})
      assert D.eq?(Throttle.shape(D.new("0.5"), false, curve), D.new("0.25"))
      assert D.eq?(Throttle.shape(D.new("-0.5"), false, curve), D.new("-0.25"))
      assert D.eq?(Throttle.shape(D.new("1"), false, curve), D.new("1"))
    end

    test "a physical quantity is applied as is" do
      # A planner asking for a fifth of full speed must get a fifth,
      # not a twenty-fifth.
      curve = Throttle.curve(%{})
      assert D.eq?(Throttle.shape(D.new("0.2"), true, curve), D.new("0.2"))
      assert D.eq?(Throttle.shape(D.new("-0.2"), true, curve), D.new("-0.2"))
    end

    test "expo blends between linear and square" do
      linear = Throttle.curve(%{expo: D.new(0)})
      half = Throttle.curve(%{expo: D.new("0.5")})

      assert D.eq?(Throttle.shape(D.new("0.5"), false, linear), D.new("0.5"))
      # Half of 0.5 plus half of 0.25.
      assert D.eq?(Throttle.shape(D.new("0.5"), false, half), D.new("0.375"))
      assert D.eq?(Throttle.shape(D.new("-0.5"), false, half), D.new("-0.375"))
      assert D.eq?(Throttle.shape(D.new("1"), false, half), D.new("1"))
    end

    test "the dead zone reads a drifting hand as zero and keeps full deflection" do
      curve = Throttle.curve(%{deadzone: D.new("0.05"), expo: D.new(0)})

      assert D.eq?(Throttle.shape(D.new("0.04"), false, curve), D.new(0))
      assert D.eq?(Throttle.shape(D.new("-0.05"), false, curve), D.new(0))
      assert D.eq?(Throttle.shape(D.new("1"), false, curve), D.new("1"))
      assert D.eq?(Throttle.shape(D.new("-1"), false, curve), D.new("-1"))
      # The remaining travel is stretched: 0.525 sits half way between
      # 0.05 and 1, so it maps to 0.5.
      assert D.eq?(Throttle.shape(D.new("0.525"), false, curve), D.new("0.5"))
    end

    test "the start offset lifts every non-zero output to the edge of motion" do
      curve =
        Throttle.curve(%{deadzone: D.new("0.05"), expo: D.new(0), start_offset: D.new("0.1")})

      assert D.eq?(Throttle.shape(D.new(0), false, curve), D.new(0))

      assert D.eq?(Throttle.shape(D.new("0.03"), false, curve), D.new(0)),
             "a hand at rest must not creep the vehicle forward"

      # The first request past the dead zone already sits at the offset.
      first = Throttle.shape(D.new("0.06"), false, curve)
      assert D.gt?(first, D.new("0.1")) and D.lt?(first, D.new("0.12"))

      reverse = Throttle.shape(D.new("-0.06"), false, curve)
      assert D.lt?(reverse, D.new("-0.1")) and D.gt?(reverse, D.new("-0.12"))

      assert D.eq?(Throttle.shape(D.new("1"), false, curve), D.new("1"))
      # 0.525 -> 0.5 after the dead zone -> 0.1 + 0.9 * 0.5.
      assert D.eq?(Throttle.shape(D.new("0.525"), false, curve), D.new("0.55"))
    end

    test "a physical quantity skips the dead zone, the curve and the start offset" do
      # A planner decelerating through a tiny velocity must be followed
      # down, not held at the edge of motion until it publishes exactly
      # zero.
      curve =
        Throttle.curve(%{deadzone: D.new("0.05"), expo: D.new(1), start_offset: D.new("0.1")})

      assert D.eq?(Throttle.shape(D.new(0), true, curve), D.new(0))
      assert D.eq?(Throttle.shape(D.new("0.02"), true, curve), D.new("0.02"))
      assert D.eq?(Throttle.shape(D.new("-0.5"), true, curve), D.new("-0.5"))
      assert D.eq?(Throttle.shape(D.new("1"), true, curve), D.new("1"))
    end

    test "the curve parameters are validated" do
      assert_raise ArgumentError, fn -> Throttle.curve(%{expo: D.new("1.5")}) end
      assert_raise ArgumentError, fn -> Throttle.curve(%{deadzone: D.new("-0.1")}) end

      assert_raise ArgumentError, fn ->
        Throttle.curve(%{deadzone: D.new("0.5"), start_offset: D.new("0.5")})
      end

      assert_raise ArgumentError, fn ->
        Throttle.curve(%{start_offset: D.new("0.5"), max_throttle: D.new("0.5")})
      end
    end
  end

  describe "the cap" do
    test "an out-of-range request cannot exceed either cap" do
      curve = Throttle.curve(%{max_throttle: D.new("0.1"), max_reverse: D.new("0.2")})

      for linear <- [false, true] do
        assert D.eq?(Throttle.shape(D.new(2), linear, curve), D.new("0.1"))
        assert D.eq?(Throttle.shape(D.new(-2), linear, curve), D.new("-0.2"))
      end
    end

    test "a narrow pulse range remains progressive and is reported after shaping" do
      {:ok, controller} = FakeController.start_link(self())
      OvcsBus.subscribe("messages")

      curve =
        Throttle.curve(%{
          deadzone: D.new("0.05"),
          expo: D.new("0.5"),
          start_offset: D.new("0.02"),
          max_throttle: D.new("0.1"),
          max_reverse: D.new("0.2")
        })

      state = throttle_state(%{controller: controller, curve: curve, throttle: nil})

      # 0.525 is the midpoint of the usable trigger travel after deadzone.
      for {request, expected_pulse} <- [
            {"0.05", "1500"},
            {"0.052", "1510.042193905817174515235457"},
            {"0.525", "1525"},
            {"1", "1550"},
            {"-1", "1400"},
            {"0", "1500"}
          ],
          reduce: state do
        state ->
          {:noreply, state} =
            Throttle.handle_info(:loop, %{state | requested_throttle: D.new(request)})

          assert_received {:pwm, 1, true, duty, 100}

          assert_in_delta D.to_float(D.mult(duty, 10_000)),
                          D.to_float(D.new(expected_pulse)),
                          0.000001

          assert_received %Message{name: :pulse_width_us, value: pulse, source: Throttle}
          assert D.eq?(D.div(pulse, 10_000), duty)
          assert_received %Message{name: :throttle, value: output, source: Throttle}
          assert D.eq?(output, state.throttle)
          state
      end
    end

    test "scales a hand's output onto [start_offset, max_throttle]" do
      # Scaled, not clipped: full trigger still means "as fast as
      # allowed", so the whole travel stays useful.
      curve =
        Throttle.curve(%{
          deadzone: D.new("0.05"),
          expo: D.new(0),
          start_offset: D.new("0.1"),
          max_throttle: D.new("0.5")
        })

      assert D.eq?(Throttle.shape(D.new("1"), false, curve), D.new("0.5"))
      # 0.525 -> 0.5 after the dead zone -> 0.1 + 0.4 * 0.5.
      assert D.eq?(Throttle.shape(D.new("0.525"), false, curve), D.new("0.3"))
      assert D.eq?(Throttle.shape(D.new(0), false, curve), D.new(0))
    end

    test "scales a physical quantity without touching its shape" do
      curve = Throttle.curve(%{max_throttle: D.new("0.5")})

      assert D.eq?(Throttle.shape(D.new("1"), true, curve), D.new("0.5"))
      assert D.eq?(Throttle.shape(D.new("0.2"), true, curve), D.new("0.1"))
      assert D.eq?(Throttle.shape(D.new(0), true, curve), D.new(0))
    end

    test "reverse follows max_throttle unless given its own cap" do
      same = Throttle.curve(%{max_throttle: D.new("0.5")})
      assert D.eq?(Throttle.shape(D.new("-1"), true, same), D.new("-0.5"))
      assert D.eq?(Throttle.shape(D.new("-1"), false, same), D.new("-0.5"))

      # Braking lives on the negative side of a Traxxas ESC, so a vehicle
      # can cap forward speed and keep the full brake.
      braking = Throttle.curve(%{max_throttle: D.new("0.5"), max_reverse: D.new(1)})
      assert D.eq?(Throttle.shape(D.new("-1"), false, braking), D.new("-1"))
      assert D.eq?(Throttle.shape(D.new("-1"), true, braking), D.new("-1"))
      assert D.eq?(Throttle.shape(D.new("1"), false, braking), D.new("0.5"))
    end

    test "no cap leaves the output untouched" do
      curve = Throttle.curve(%{})
      assert D.eq?(Throttle.shape(D.new("1"), false, curve), D.new("1"))
      assert D.eq?(Throttle.shape(D.new("-1"), true, curve), D.new("-1"))
    end
  end
end
