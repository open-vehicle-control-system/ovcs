defmodule RosBridge.Publishers.RangeTest do
  use ExUnit.Case, async: true

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2.SensorMsgs.Msg.Range
  alias RosBridge.Publishers.Range, as: RangePublisher

  @state %{frame_id: "ultrasound_rear_left", radiation_type: :ultrasound}

  defp sample(distance),
    do: %Sample{
      distance: distance,
      range: {0.03, 4.5},
      field_of_view: 1.0,
      measured_at: 2_250_000_000
    }

  test "carries the distance, the sensor's range and its field of view" do
    message = RangePublisher.range(sample(1.234), @state)
    assert {message.range, message.min_range, message.max_range} == {1.234, 0.03, 4.5}
    assert message.header.frame_id == "ultrasound_rear_left"
    assert {message.header.stamp.sec, message.header.stamp.nanosec} == {2, 250_000_000}
  end

  test "uses REP 117's infinities outside the range, encoded as IEEE infinities" do
    assert RangePublisher.range(sample(:beyond_range), @state).range == :infinity
    assert RangePublisher.range(sample(:below_range), @state).range == :neg_infinity

    encoded = Range.encode(RangePublisher.range(sample(:beyond_range), @state))
    assert binary_part(encoded, byte_size(encoded) - 8, 4) == <<0, 0, 0x80, 0x7F>>
  end

  test "places the radiation type right after the frame id, as CDR does" do
    # 8 bytes of stamp, a 4-byte length, then "ultrasound_rear_left" and its NUL.
    encoded = Range.encode(RangePublisher.range(sample(1.5), @state))
    frame_end = 8 + 4 + byte_size("ultrasound_rear_left") + 1

    <<_::binary-size(frame_end), radiation, _pad::binary-size(2), fov::little-float-32,
      min::little-float-32, _::binary>> = encoded

    assert radiation == 0
    assert_in_delta fov, 1.0, 1.0e-6
    assert_in_delta min, 0.03, 1.0e-6
  end
end
