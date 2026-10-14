defmodule Ros2.SensorMsgs.Msg.LaserScan do
  @moduledoc """
  ROS 2 `sensor_msgs/LaserScan`: one revolution of a planar scanner,
  as ranges at evenly spaced angles from `angle_min`. A range outside
  `range_min..range_max` is not a measurement; REP 117's `+Inf` means
  no return. `parse/1` keeps IEEE infinities as `:infinity` /
  `:neg_infinity`, as Gazebo sends them.
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

  def parse(body) when is_binary(body) do
    with {:ok, header, rest} <- Header.parse(body) do
      input = {rest, byte_size(body) - byte_size(rest)}
      {angle_min, input} = read_f32(input)
      {angle_max, input} = read_f32(input)
      {angle_increment, input} = read_f32(input)
      {time_increment, input} = read_f32(input)
      {scan_time, input} = read_f32(input)
      {range_min, input} = read_f32(input)
      {range_max, input} = read_f32(input)
      {ranges, input} = read_sequence(input, &read_f32/1)
      {intensities, {rest, _offset}} = read_sequence(input, &read_f32/1)

      {:ok,
       %__MODULE__{
         header: header,
         angle_min: angle_min,
         angle_max: angle_max,
         angle_increment: angle_increment,
         time_increment: time_increment,
         scan_time: scan_time,
         range_min: range_min,
         range_max: range_max,
         ranges: ranges,
         intensities: intensities
       }, rest}
    end
  end
end
