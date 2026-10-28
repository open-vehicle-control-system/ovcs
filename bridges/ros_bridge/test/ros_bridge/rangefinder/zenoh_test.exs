defmodule RosBridge.Rangefinder.ZenohTest do
  use ExUnit.Case, async: true

  alias OvcsDrivers.Rangefinder.Sample
  alias Ros2Zenoh.SensorMsgs.Msg.LaserScan
  alias RosBridge.Rangefinder.Zenoh

  defp fan(ranges),
    do: %LaserScan{
      angle_min: -0.5,
      angle_max: 0.5,
      range_min: 0.03,
      range_max: 4.5,
      ranges: ranges
    }

  test "reports the fan's nearest return, its span as the field of view" do
    assert %Sample{distance: 0.8, range: {0.03, 4.5}, field_of_view: 1.0, measured_at: 7} =
             Zenoh.sample(fan([:infinity, 1.2, 0.8, :infinity]), 7)
  end

  test "reports a fan with no return as beyond range" do
    assert Zenoh.sample(fan([:infinity, :infinity]), 0).distance == :beyond_range
    assert Zenoh.sample(fan([4.8]), 0).distance == :beyond_range
    assert Zenoh.sample(fan([:nan, :nan]), 0).distance == :beyond_range
  end

  test "reports a ray below range_min as below range" do
    assert Zenoh.sample(fan([1.0, :neg_infinity]), 0).distance == :below_range
    assert Zenoh.sample(fan([1.0, 0.01]), 0).distance == :below_range
  end
end
