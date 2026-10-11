defmodule Ros2.StereoMsgs.DisparityImageTest do
  @moduledoc """
  Byte-equality against `test/support/golden_cdr.json`, whose bytes were
  validated by deserialising them with ROS 2. See
  `test/support/golden_cdr.md` for the provenance.

  `DisparityImage` is the awkward one to encode: it nests a whole
  `sensor_msgs/Image`, which ends in a byte sequence (alignment 1), and
  a `RegionOfInterest`, which ends in a `bool`. Both leave the buffer
  tail at an arbitrary offset, so the `float32` fields that follow each
  of them need explicit re-alignment. There is no `parse/1` — the
  bridge only emits disparity — so a round-trip cannot catch a mistake
  here, which is exactly why a golden vector is worth having.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.SensorMsgs.Msg.Image
  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.StereoMsgs.Msg.DisparityImage

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp header do
    %Header{
      stamp: %Time{sec: 1_735_689_600, nanosec: 123_456_789},
      frame_id: "stereo_right"
    }
  end

  defp disparity_image do
    %DisparityImage{
      header: header(),
      image: %Image{
        header: header(),
        height: 2,
        width: 2,
        encoding: "32FC1",
        is_bigendian: 0,
        step: 8,
        data: <<
          1.5::little-float-32,
          2.5::little-float-32,
          3.5::little-float-32,
          0.0::little-float-32
        >>
      },
      f: 321.5,
      t: 0.06,
      valid_window: %RegionOfInterest{
        x_offset: 8,
        y_offset: 4,
        height: 262,
        width: 464,
        do_rectify: false
      },
      min_disparity: 0.0,
      max_disparity: 47.0,
      delta_d: 0.0625
    }
  end

  test "encodes to the bytes ROS 2 reads back correctly" do
    assert DisparityImage.encode(disparity_image()) == golden("disparity_image")
  end

  test "f is 4-aligned after the unaligned tail of the nested Image" do
    # The image's trailing byte sequence ends off a 4-boundary here, so
    # without the `align_to(4)` before `f`, f, T and everything after
    # them would shift.
    encoded = DisparityImage.encode(disparity_image())
    {offset, 4} = :binary.match(encoded, <<321.5::little-float-32>>)
    assert rem(offset, 4) == 0
  end
end
