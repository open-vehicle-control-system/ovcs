defmodule VmsCore.Components.Matek.PM12S3Test do
  @moduledoc """
  Analog readings to battery voltage and current, published once per
  controller loop, and nil while the controller is not alive.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Matek.PM12S3

  defp state(overrides \\ %{}) do
    {:ok, state} =
      PM12S3.init(
        Map.merge(
          %{
            controller: Ctrl,
            voltage_pin: 1,
            current_pin: 2,
            current_scale: "0.04",
            current_offset: "0.5"
          },
          overrides
        )
      )

    state
  end

  defp feed(state, messages) do
    Enum.reduce(messages, state, fn message, state ->
      {:noreply, state} = PM12S3.handle_info(message, state)
      state
    end)
  end

  test "a full-scale reading is 5 V on the pad, 105 V behind the divider" do
    assert D.eq?(PM12S3.voltage(16_383, D.new(21)), D.new("105.00"))
  end

  test "the pad's voltage above the offset, per the sensor's scale, is the current" do
    # 1.5 V on the pad: 1 V above a 0.5 V offset at 40 mV/A.
    assert D.eq?(PM12S3.current(4915, D.new("0.04"), D.new("0.5")), D.new("25.0"))
  end

  test "readings are published when the controller closes its loop" do
    OvcsBus.subscribe("messages")

    feed(state(), [
      %Message{name: :received_analog_pin1_value, value: 3900, source: Ctrl},
      %Message{name: :received_analog_pin2_value, value: 1638, source: Ctrl}
    ])
    |> feed([%Message{name: :is_alive, value: true, source: Ctrl}])

    assert_received %Message{name: :voltage, value: voltage, source: PM12S3, unit: "V"}
    assert D.eq?(voltage, D.new("25.00"))
    assert_received %Message{name: :current, value: current, source: PM12S3, unit: "A"}
    assert D.eq?(current, D.new("0.0"))
  end

  test "a controller that is not alive reads as nil, not as its last value" do
    OvcsBus.subscribe("messages")

    feed(state(), [
      %Message{name: :received_analog_pin1_value, value: 3900, source: Ctrl},
      %Message{name: :is_alive, value: false, source: Ctrl}
    ])

    assert_received %Message{name: :voltage, value: nil, source: PM12S3}
    assert_received %Message{name: :current, value: nil, source: PM12S3}
  end

  test "without a current pin only the voltage is published" do
    OvcsBus.subscribe("messages")

    feed(state(%{current_pin: nil}), [%Message{name: :is_alive, value: true, source: Ctrl}])

    assert_received %Message{name: :voltage, source: PM12S3}
    refute_received %Message{name: :current, source: PM12S3}
  end

  test "only the configured controller is read" do
    OvcsBus.subscribe("messages")

    feed(state(), [
      %Message{name: :received_analog_pin1_value, value: 3900, source: Other},
      %Message{name: :is_alive, value: true, source: Other}
    ])

    refute_received %Message{name: :voltage, source: PM12S3}
  end
end
