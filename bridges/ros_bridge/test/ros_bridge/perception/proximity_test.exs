defmodule RosBridge.Perception.ProximityTest do
  @moduledoc """
  The nearest return, and the labels per sector.
  """
  use ExUnit.Case, async: true

  alias Ros2.SensorMsgs.Msg.LaserScan
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.VisualizationMsgs.Msg.Marker
  alias RosBridge.Perception.Proximity

  @state %{within_m: 3.0, sector_rad: :math.pi() / 2, danger_m: 0.5, caution_m: 1.0}

  # Four beams, a quarter turn apart: ahead, left, behind, right.
  defp scan(ranges) do
    %LaserScan{
      header: %Header{frame_id: "lidar_link"},
      angle_min: 0.0,
      angle_max: 3 * :math.pi() / 2,
      angle_increment: :math.pi() / 2,
      range_min: 0.1,
      range_max: 12.0,
      ranges: ranges
    }
  end

  test "keeps returns within reach, dropping infinities and out-of-range ones" do
    returns = Proximity.returns_within(scan([0.4, :infinity, 5.0, 0.05]), 3.0)
    assert returns == [{0.0, 0.4}]
  end

  test "the nearest return, or infinity when none is within reach" do
    scan = scan([2.0, 0.7, :infinity, 1.5])
    assert Proximity.nearest(scan, Proximity.returns_within(scan, 3.0)).range == 0.7
    assert Proximity.nearest(scan, []).range == :infinity
  end

  test "labels each sector's nearest return, after clearing the last labels" do
    scan = scan([0.4, 2.0, :infinity, :infinity])

    %{markers: [clear | labels]} =
      Proximity.labels(scan, Proximity.returns_within(scan, 3.0), @state)

    assert clear.action == Marker.delete_all()
    texts = for %Marker{type: 9, text: text} <- labels, do: text
    assert texts == ["0.40", "2.00"]
    [near_dot | _] = labels
    assert near_dot.color.r == 1.0 and near_dot.color.g < 0.5
  end
end
