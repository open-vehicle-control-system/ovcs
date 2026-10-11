defmodule Ros2.SensorMsgs.Msg.LaserScan do
  @moduledoc """
  ROS 2 `sensor_msgs/LaserScan`: one revolution of a planar scanner,
  as ranges at evenly spaced angles from `angle_min`. A range outside
  `range_min..range_max` (here 0.0) means no return.
  """

  import Ros2.Cdr
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: %Header{},
            angle_min: 0.0,
            angle_max: 0.0,
            angle_increment: 0.0,
            time_increment: 0.0,
            scan_time: 0.0,
            range_min: 0.0,
            range_max: 0.0,
            ranges: [],
            intensities: []

  @dds_type "sensor_msgs::msg::dds_::LaserScan_"
  @type_hash "RIHS01_64c191398013af96509d518dac71d5164f9382553fce5c1f8cca5be7924bd828"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = scan) do
    Header.encode(scan.header)
    |> f32(scan.angle_min)
    |> f32(scan.angle_max)
    |> f32(scan.angle_increment)
    |> f32(scan.time_increment)
    |> f32(scan.scan_time)
    |> f32(scan.range_min)
    |> f32(scan.range_max)
    |> sequence(scan.ranges, &f32/2)
    |> sequence(scan.intensities, &f32/2)
  end
end
