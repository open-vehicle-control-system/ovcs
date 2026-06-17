defmodule Ros2.SensorMsgs.Msg.RegionOfInterest do
  @moduledoc """
  ROS 2 `sensor_msgs/RegionOfInterest`: four `uint32`s + one `bool`.
  No internal padding — every primitive after the previous u32 is
  4-aligned naturally; the trailing bool (alignment 1) appends at
  offset 16.
  """
  use Ros2.Common

  defstruct x_offset: 0, y_offset: 0, height: 0, width: 0, do_rectify: false

  def encode(%__MODULE__{} = roi) do
    encode_uint32(roi.x_offset) <>
      encode_uint32(roi.y_offset) <>
      encode_uint32(roi.height) <>
      encode_uint32(roi.width) <>
      encode_bool(roi.do_rectify)
  end

  def parse(<<
        x_offset::little-unsigned-integer-size(32),
        y_offset::little-unsigned-integer-size(32),
        height::little-unsigned-integer-size(32),
        width::little-unsigned-integer-size(32),
        do_rectify::little-unsigned-integer-size(8),
        rest::binary
      >>) do
    {:ok,
     %__MODULE__{
       x_offset: x_offset,
       y_offset: y_offset,
       height: height,
       width: width,
       do_rectify: do_rectify == 1
     }, rest}
  end

  def parse(_), do: {:error, :malformed, :region_of_interest}
end
