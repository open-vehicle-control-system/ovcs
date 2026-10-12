defmodule RosBridge.Lidar.ZenohTest do
  use ExUnit.Case, async: true

  alias OvcsDrivers.Lidar.Scan
  alias Ros2.SensorMsgs.Msg.LaserScan
  alias RosBridge.Lidar.Zenoh

  test "places each ray at its angle in [0, 2π), no return as 0.0" do
    laser_scan = %LaserScan{
      angle_min: -:math.pi(),
      angle_increment: :math.pi() / 2,
      scan_time: 0.1,
      range_min: 0.05,
      range_max: 12.0,
      ranges: [1.0, :infinity, 0.01, 3.0]
    }

    assert %Scan{points: points, started_at: 42, duration_ns: 100_000_000, range: {0.05, 12.0}} =
             Zenoh.scan(laser_scan, 42)

    assert [{a0, 1.0, 1}, {a1, 0.0, 0}, {a2, 0.0, 0}, {a3, 3.0, 1}] = points
    assert_in_delta a0, :math.pi(), 1.0e-9
    assert_in_delta a1, 3 * :math.pi() / 2, 1.0e-9
    assert_in_delta a2, 0.0, 1.0e-9
    assert_in_delta a3, :math.pi() / 2, 1.0e-9
  end
end
