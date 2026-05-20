defmodule Ros2.StereoMsgs.Msg.DisparityImage do
  @moduledoc """
  ROS 2 `stereo_msgs/DisparityImage`. Field order on the wire:

      Header                       header
      sensor_msgs/Image            image           # raw disparity (16UC1)
      float32                      f               # focal length (pixels)
      float32                      T               # baseline (metres)
      sensor_msgs/RegionOfInterest valid_window
      float32                      min_disparity
      float32                      max_disparity
      float32                      delta_d         # smallest disparity step

  CDR alignment hazards (offsets are relative to the start of
  the encapsulated body):

    * `Image` ends with a byte sequence (alignment 1), so the
      buffer tail after `Image.encode` is *not* 4-aligned. The
      next field `f` is `float32` → we `align_to(4)`.
    * `RegionOfInterest` ends with a `bool` (u8). Same situation
      before `min_disparity` → another `align_to(4)`.
    * All other fields are u32/float32 runs that stay
      4-aligned naturally.

  No `parse/1` — the bridge only emits disparity. Add when
  something consumes it locally.
  """
  use Ros2.Common

  alias Ros2.SensorMsgs.Msg.Image
  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.StdMsgs.Msg.Header

  defstruct [
    :header,
    image: %Image{},
    f: 0.0,
    t: 0.0,
    valid_window: %RegionOfInterest{},
    min_disparity: 0.0,
    max_disparity: 0.0,
    delta_d: 0.0
  ]

  # Captured against ROS 2 Jazzy via `ros2 topic info -v` on an
  # rclpy publisher of `stereo_msgs/DisparityImage`. Refresh on
  # distro bumps.
  @dds_type "stereo_msgs::msg::dds_::DisparityImage_"
  @type_hash "RIHS01_1ec1ff6b5bace919e4544a37f2d96ead9f81783701b7b7a4d97a09325ecf2711"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = disparity) do
    Header.encode(disparity.header)
    |> Kernel.<>(Image.encode(disparity.image))
    |> align_to(4)
    |> Kernel.<>(encode_float32(disparity.f))
    |> Kernel.<>(encode_float32(disparity.t))
    |> Kernel.<>(RegionOfInterest.encode(disparity.valid_window))
    |> align_to(4)
    |> Kernel.<>(encode_float32(disparity.min_disparity))
    |> Kernel.<>(encode_float32(disparity.max_disparity))
    |> Kernel.<>(encode_float32(disparity.delta_d))
  end
end
