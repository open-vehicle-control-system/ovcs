defmodule VmsCore.Components.OVCS.InputCurveTest do
  @moduledoc """
  The hand's curve: a dead zone and an expo between a commander and the
  actuator, relayed under its own name from exactly one source.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.InputCurve

  @hand SomeRadioThrottle
  @curve_name Vms.RadioThrottleInputCurve

  defp state(curve \\ %{}),
    do: %{process_name: @curve_name, throttle_source: @hand, curve: InputCurve.curve(curve)}

  describe "relaying" do
    test "shapes its source's request and publishes it under its own name" do
      OvcsBus.subscribe("messages")
      curve = %{deadzone: D.new("0.05"), expo: D.new(0)}

      {:noreply, _} =
        InputCurve.handle_info(
          %Message{name: :requested_throttle, value: D.new("0.525"), source: @hand},
          state(curve)
        )

      assert_received %Message{name: :requested_throttle, value: shaped, source: @curve_name}
      assert D.eq?(shaped, D.new("0.5"))
      # Its input goes out too, so the curve is visible from one source.
      assert_received %Message{name: :input_throttle, value: input, source: @curve_name}
      assert D.eq?(input, D.new("0.525"))
    end

    test "another component's request is not relayed" do
      OvcsBus.subscribe("messages")

      {:noreply, _} =
        InputCurve.handle_info(
          %Message{name: :requested_throttle, value: D.new("1"), source: Impostor},
          state()
        )

      refute_received %Message{source: @curve_name}
    end
  end

  describe "the curve" do
    test "with no parameters the request is untouched" do
      curve = InputCurve.curve(%{})
      assert D.eq?(InputCurve.shape(D.new("0.5"), curve), D.new("0.5"))
      assert D.eq?(InputCurve.shape(D.new("-0.3"), curve), D.new("-0.3"))
    end

    test "the dead zone reads a drifting hand as zero and keeps full deflection" do
      curve = InputCurve.curve(%{deadzone: D.new("0.05")})

      assert D.eq?(InputCurve.shape(D.new("0.04"), curve), D.new(0))
      assert D.eq?(InputCurve.shape(D.new("-0.05"), curve), D.new(0))
      assert D.eq?(InputCurve.shape(D.new("1"), curve), D.new("1"))
      assert D.eq?(InputCurve.shape(D.new("-1"), curve), D.new("-1"))
      # The remaining travel is stretched: 0.525 sits half way between
      # 0.05 and 1, so it maps to 0.5.
      assert D.eq?(InputCurve.shape(D.new("0.525"), curve), D.new("0.5"))
    end

    test "expo blends between linear and square, keeping the sign" do
      half = InputCurve.curve(%{expo: D.new("0.5")})
      square = InputCurve.curve(%{expo: D.new(1)})

      # Half of 0.5 plus half of 0.25.
      assert D.eq?(InputCurve.shape(D.new("0.5"), half), D.new("0.375"))
      assert D.eq?(InputCurve.shape(D.new("-0.5"), half), D.new("-0.375"))
      assert D.eq?(InputCurve.shape(D.new("1"), half), D.new("1"))
      assert D.eq?(InputCurve.shape(D.new("0.5"), square), D.new("0.25"))
    end

    test "a request beyond the range reads as full deflection" do
      curve = InputCurve.curve(%{deadzone: D.new("0.05"), expo: D.new("0.5")})
      assert D.eq?(InputCurve.shape(D.new(2), curve), D.new(1))
      assert D.eq?(InputCurve.shape(D.new(-2), curve), D.new(-1))
    end

    test "the parameters are validated" do
      assert_raise ArgumentError, fn -> InputCurve.curve(%{expo: D.new("1.5")}) end
      assert_raise ArgumentError, fn -> InputCurve.curve(%{deadzone: D.new("-0.1")}) end
      assert_raise ArgumentError, fn -> InputCurve.curve(%{deadzone: D.new(1)}) end
    end
  end
end
