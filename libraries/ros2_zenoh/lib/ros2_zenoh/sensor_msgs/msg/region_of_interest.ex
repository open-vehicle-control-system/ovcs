defmodule Ros2Zenoh.SensorMsgs.Msg.RegionOfInterest do
  @moduledoc """
  ROS 2 `sensor_msgs/RegionOfInterest`: four `uint32`s + one `bool`.
  No internal padding — every primitive after the previous u32 is
  4-aligned naturally; the trailing bool (alignment 1) appends at
  offset 16.
  """
  use Ros2Zenoh.Common

  defstruct x_offset: 0, y_offset: 0, height: 0, width: 0, do_rectify: false

  def msg_definition do
    """
    # This message is used to specify a region of interest within an image.
    #
    # When used to specify the ROI setting of the camera when the image was
    # taken, the height and width fields should either match the height and
    # width fields for the associated image; or height = width = 0
    # indicates that the full resolution image was captured.

    uint32 x_offset  # Leftmost pixel of the ROI
                     # (0 if the ROI includes the left edge of the image)
    uint32 y_offset  # Topmost pixel of the ROI
                     # (0 if the ROI includes the top edge of the image)
    uint32 height    # Height of ROI
    uint32 width     # Width of ROI

    # True if a distinct rectified ROI should be calculated from the "raw"
    # ROI in this message. Typically this should be False if the full image
    # is captured (ROI not used), and True if a subwindow is captured (ROI
    # used).
    bool do_rectify
    """
  end

  def dependencies, do: []

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
