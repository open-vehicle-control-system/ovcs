defmodule RosBridge.Publishers.LaserScanTest do
  use ExUnit.Case, async: true

  alias OvcsDrivers.Lidar.Scan
  alias RosBridge.Publishers.LaserScan

  defp scan(points),
    do: %Scan{
      points: points,
      started_at: 1_500_000_000,
      duration_ns: 100_000_000,
      range: {0.05, 12.0}
    }

  test "bins a revolution over [-π, π), keeping each slot's nearest return" do
    message =
      LaserScan.laser_scan(
        scan([
          {0.0, 2.0, 40},
          {0.001, 1.5, 30},
          {:math.pi() / 2, 3.0, 20},
          {3 * :math.pi() / 2, 4.0, 10}
        ]),
        4,
        "laser"
      )

    # Slots start at -π, -π/2, 0 and π/2.
    assert message.ranges == [0.0, 4.0, 1.5, 3.0]
    assert message.intensities == [0.0, 10.0, 30.0, 20.0]
    assert message.angle_min == -:math.pi()
    assert_in_delta message.angle_max, :math.pi() / 2, 1.0e-9
    assert message.scan_time == 0.1
    assert message.header.stamp.sec == 1 and message.header.stamp.nanosec == 500_000_000
  end

  test "drops returns outside the sensor's range" do
    message = LaserScan.laser_scan(scan([{0.0, 0.0, 0}, {0.0, 20.0, 5}]), 4, "laser")
    assert message.ranges == [0.0, 0.0, 0.0, 0.0]
  end
end
