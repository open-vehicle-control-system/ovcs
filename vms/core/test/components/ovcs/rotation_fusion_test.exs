defmodule VmsCore.Components.OVCS.RotationFusionTest do
  @moduledoc """
  One shaft's rotation from a motor controller and a pulse sensor on a
  gear: priority, the exact zero, the sign, fallback and the
  cross-check.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.RotationFusion

  @fusion Vms.MotorRotation
  @vesc Vms.Vesc
  @spur SpurSensor
  @actuator Actuator

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        process_name: @fusion,
        sources: [
          %{source: @vesc, ratio: D.new(1), signed: true, noise_rpm: D.new(5)},
          %{source: @spur, ratio: D.from_float(54 / 13), signed: false, noise_rpm: D.new(0)}
        ],
        readings: %{},
        direction_source: nil,
        sign: 1,
        cross_check_from_rpm: D.new(450),
        cross_check_tolerance: D.new("0.1"),
        cross_check_hold_ms: 500,
        gap: nil,
        mismatch_since: nil,
        fault: false
      },
      overrides
    )
  end

  defp rotation(source, value, state) do
    {:noreply, state} =
      RotationFusion.handle_info(
        %Message{name: :rotation_per_minute, value: value, source: source},
        state
      )

    state
  end

  defp published_rotation do
    receive do
      %Message{name: :rotation_per_minute, value: value, source: @fusion} -> {:ok, value}
    after
      0 -> :none
    end
  end

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  describe "priority" do
    test "the first live source gives the value, signed as it reads" do
      state = state() |> then(&rotation(@spur, D.new("108.0"), &1))
      assert {:ok, _} = published_rotation()

      rotation(@vesc, D.new(-450), state)
      assert {:ok, value} = published_rotation()
      assert D.eq?(value, D.new(-450))
    end

    test "only a sample of the active source is published" do
      state = rotation(@vesc, D.new(450), state())
      assert {:ok, _} = published_rotation()

      rotation(@spur, D.new("108.0"), state)
      assert published_rotation() == :none
    end

    test "when the active source dies the next one takes over, scaled onto the output" do
      state =
        state()
        |> then(&rotation(@vesc, D.new(450), &1))
        |> then(&rotation(@vesc, nil, &1))

      assert RotationFusion.active_source(state) == nil
      flush()

      rotation(@spur, D.new("108.0"), state)
      assert {:ok, value} = published_rotation()
      # 108 spur rpm times 54/13.
      assert_in_delta D.to_float(value), 448.6, 0.1
    end

    test "with every source dead the rotation is unknown" do
      state = rotation(@vesc, D.new(450), state())
      flush()
      rotation(@vesc, nil, state)
      assert published_rotation() == {:ok, nil}
    end
  end

  describe "the zero" do
    test "every live source within its noise reads exactly zero" do
      state =
        state()
        |> then(&rotation(@spur, D.new("0.0"), &1))
        |> then(&rotation(@vesc, D.new(-2), &1))

      assert D.eq?(RotationFusion.rotation(state), D.new(0))
    end

    test "a source above its noise keeps the reading real" do
      state =
        state()
        |> then(&rotation(@spur, D.new("24.0"), &1))
        |> then(&rotation(@vesc, D.new(3), &1))

      refute D.eq?(RotationFusion.rotation(state), D.new(0))
    end
  end

  describe "the sign of an unsigned source" do
    test "follows the last signed reading" do
      state =
        state()
        |> then(&rotation(@vesc, D.new(-450), &1))
        |> then(&rotation(@vesc, nil, &1))
        |> then(&rotation(@spur, D.new("108.0"), &1))

      assert D.negative?(RotationFusion.rotation(state))
    end

    test "follows the direction source's throttle when there is one, zero keeping it" do
      state =
        state(%{
          direction_source: @actuator,
          sources: [%{source: @spur, ratio: D.new(1), signed: false, noise_rpm: D.new(0)}]
        })

      {:noreply, state} =
        RotationFusion.handle_info(
          %Message{name: :throttle, value: D.new("-0.2"), source: @actuator},
          state
        )

      {:noreply, state} =
        RotationFusion.handle_info(
          %Message{name: :throttle, value: D.new(0), source: @actuator},
          state
        )

      state = rotation(@spur, D.new("100.0"), state)
      assert D.eq?(RotationFusion.rotation(state), D.new(-100))
    end
  end

  describe "the cross-check" do
    defp readings(vesc, spur),
      do: state(%{readings: %{@vesc => D.new(vesc), @spur => D.new(spur)}})

    test "below the check speed nothing is compared" do
      state = RotationFusion.cross_check(readings(100, 60), 0)
      assert state.gap == nil
      refute state.fault
    end

    test "agreeing sources raise nothing" do
      state = RotationFusion.cross_check(readings(1000, 980), 0)
      assert D.eq?(state.gap, D.new("0.02"))
      refute state.fault
    end

    test "a gap raises the fault only once it has lasted the hold time" do
      state = RotationFusion.cross_check(readings(1000, 700), 0)
      refute state.fault

      state = RotationFusion.cross_check(state, 499)
      refute state.fault

      state = RotationFusion.cross_check(state, 500)
      assert state.fault
    end

    test "a gap that closes resets the hold" do
      state = RotationFusion.cross_check(readings(1000, 700), 0)
      state = RotationFusion.cross_check(%{state | readings: readings(1000, 990).readings}, 300)
      state = RotationFusion.cross_check(%{state | readings: readings(1000, 700).readings}, 600)
      refute state.fault
    end

    test "a motor controller claiming rest while the gear turns is a gap" do
      # The fast reading counts: the check runs as soon as any source is
      # above the check speed, and the gap is a fraction of it.
      state = RotationFusion.cross_check(readings(3, 450), 0)
      assert D.gt?(state.gap, D.new("0.9"))
    end
  end

  defp flush do
    receive do
      %Message{} -> flush()
    after
      0 -> :ok
    end
  end
end
