defmodule Ros2Zenoh.StereoMsgs.Msg.DisparityImage do
  @moduledoc """
  ROS 2 `stereo_msgs/DisparityImage`. Field order on the wire:

      Header                       header
      sensor_msgs/Image            image           # float disparity (32FC1)
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

  Encode only, no `parse/1`.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.SensorMsgs.Msg.{Image, RegionOfInterest}
  alias Ros2Zenoh.StdMsgs.Msg.Header

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

  def msg_definition do
    """
    # Separate header for compatibility with current TimeSynchronizer.
    # Likely to be removed in a later release, use image.header instead.
    std_msgs/Header header

    # Floating point disparity image. The disparities are pre-adjusted for any
    # x-offset between the principal points of the two cameras (in the case
    # that they are verged). That is: d = x_l - x_r - (cx_l - cx_r)
    sensor_msgs/Image image

    # Stereo geometry. For disparity d, the depth from the camera is Z = fT/d.
    float32 f # Focal length, pixels
    float32 t # Baseline, world units

    # Subwindow of (potentially) valid disparity values.
    sensor_msgs/RegionOfInterest valid_window

    # The range of disparities searched.
    # In the disparity image, any disparity less than min_disparity is invalid.
    # The disparity search range defines the horopter, or 3D volume that the
    # stereo algorithm can "see". Points with Z outside of:
    #     Z_min = fT / max_disparity
    #     Z_max = fT / min_disparity
    # could not be found.
    float32 min_disparity
    float32 max_disparity

    # Smallest allowed disparity increment. The smallest achievable depth range
    # resolution is delta_Z = (Z^2/fT)*delta_d.
    float32 delta_d
    """
  end

  def dependencies,
    do: [
      Header,
      Image,
      RegionOfInterest
    ]

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
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
