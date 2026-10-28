defmodule Ros2Zenoh.SensorMsgs.Msg.LaserScanTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.RmwZenoh
  alias Ros2Zenoh.SensorMsgs.Msg.LaserScan
  alias Ros2Zenoh.StdMsgs.Msg.Header

  test "round-trips through encode → decode_payload → parse, infinities included" do
    scan = %LaserScan{
      header: %Header{stamp: %Time{sec: 12, nanosec: 345}, frame_id: "laser"},
      angle_min: -0.5,
      angle_max: 0.5,
      angle_increment: 0.25,
      time_increment: 0.0,
      scan_time: 0.125,
      range_min: 0.03,
      range_max: 4.5,
      ranges: [1.5, :infinity, :neg_infinity, 0.25, 2.0],
      intensities: [0.0, 0.0, 0.0, 0.0, 0.0]
    }

    {:ok, body} = RmwZenoh.decode_payload(RmwZenoh.encode_payload(scan))
    {:ok, parsed, ""} = LaserScan.parse(body)

    assert parsed.header == scan.header
    assert parsed.ranges == scan.ranges
    assert parsed.intensities == scan.intensities
    assert {parsed.angle_min, parsed.angle_increment, parsed.scan_time} == {-0.5, 0.25, 0.125}
    assert_in_delta parsed.range_min, 0.03, 1.0e-6
  end

  test "parses NaN as :nan" do
    scan = %LaserScan{
      header: %Header{stamp: %Time{sec: 0, nanosec: 0}, frame_id: ""},
      ranges: [1.0]
    }

    {:ok, body} = RmwZenoh.decode_payload(RmwZenoh.encode_payload(scan))

    # The last 8 bytes are the one range, then the empty intensities' length.
    patched = binary_part(body, 0, byte_size(body) - 8) <> <<0x7FC00000::little-32, 0::32>>
    assert {:ok, %LaserScan{ranges: [:nan]}, ""} = LaserScan.parse(patched)
  end
end
