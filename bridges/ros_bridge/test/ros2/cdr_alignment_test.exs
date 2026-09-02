defmodule Ros2.CdrAlignmentTest do
  @moduledoc """
  CDR alignment invariants for the message types the perception
  pipeline puts on the wire.

  Round-trip tests cannot catch an alignment bug: if the encoder and
  the parser make the same wrong assumption they agree with each other
  and disagree only with real ROS peers. So every assertion here locates
  a field in the *raw bytes* by a distinctive sentinel value and checks
  its absolute offset, independently of our own parser.

  Each case is parametrised over `frame_id` length. A name one character
  longer shifts everything after the header between alignment residues,
  which is exactly the axis the `float64[]` bug in `Ros2.Common` hid
  along.

  `sensor_msgs/Image` and `stereo_msgs/DisparityImage` are encode-only
  in this bridge (nothing consumes them locally), so they get alignment
  assertions but no round-trip.

  Not covered here: golden byte vectors captured from a live
  `rclpy` / `rmw_zenoh` publisher, which is the only check that
  validates against the real peer rather than against ourselves. That
  needs a running ROS 2 stack — worth adding to the calibration
  container as follow-up.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.SensorMsgs.Msg.CompressedImage
  alias Ros2.SensorMsgs.Msg.Image
  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.StereoMsgs.Msg.DisparityImage

  # Distinctive enough that :binary.match cannot mistake them for
  # neighbouring zeroed fields or ASCII.
  @step 287_454_020
  @data "SENTINEL-PAYLOAD"
  @focal 1234.5
  @baseline 6789.25
  @delta_d 0.0625

  # The two residues that matter: header lengths either side of an
  # 8-boundary, so a fixed-padding assumption is wrong for half of them.
  @frame_id_lengths 8..16

  defp header(frame_id) do
    %Header{
      stamp: %Time{sec: 1_700_000_000, nanosec: 123_456_789},
      frame_id: frame_id
    }
  end

  defp frame_id(len), do: String.duplicate("x", len)

  defp offset_of!(encoded, needle) do
    case :binary.match(encoded, needle) do
      {offset, _len} -> offset
      :nomatch -> flunk("could not locate the sentinel in the encoded body")
    end
  end

  defp assert_aligned!(encoded, needle, alignment, label) do
    offset = offset_of!(encoded, needle)

    assert rem(offset, alignment) == 0,
           "#{label} starts at offset #{offset}, #{rem(offset, alignment)} bytes past a #{alignment}-boundary"
  end

  describe "sensor_msgs/Image" do
    defp image(frame_id) do
      %Image{
        header: header(frame_id),
        height: 480,
        width: 640,
        encoding: "32FC1",
        is_bigendian: 0,
        step: @step,
        data: @data
      }
    end

    for len <- @frame_id_lengths do
      # `encoding` is a string followed by a u8, so Image must use the
      # unaligned string encoder; over-padding there shifts `step` and
      # every byte of `data` on the receiver.
      test "step stays 4-aligned with a #{len}-char frame_id" do
        encoded = Image.encode(image(frame_id(unquote(len))))
        assert_aligned!(encoded, <<@step::little-unsigned-integer-size(32)>>, 4, "step")
      end

      test "data stays 4-aligned with a #{len}-char frame_id" do
        encoded = Image.encode(image(frame_id(unquote(len))))
        assert_aligned!(encoded, @data, 4, "data")
      end
    end
  end

  describe "sensor_msgs/CompressedImage" do
    defp compressed_image(frame_id) do
      %CompressedImage{header: header(frame_id), format: "jpeg", data: @data}
    end

    for len <- @frame_id_lengths do
      test "data stays 4-aligned with a #{len}-char frame_id" do
        encoded = CompressedImage.encode(compressed_image(frame_id(unquote(len))))
        assert_aligned!(encoded, @data, 4, "data")
      end

      test "round-trips with a #{len}-char frame_id" do
        message = compressed_image(frame_id(unquote(len)))
        assert {:ok, parsed, <<>>} = CompressedImage.parse(CompressedImage.encode(message))
        assert parsed == message
      end
    end
  end

  describe "sensor_msgs/RegionOfInterest" do
    test "the trailing bool lands at offset 16" do
      roi = %RegionOfInterest{
        x_offset: 1,
        y_offset: 2,
        height: 3,
        width: 4,
        do_rectify: true
      }

      encoded = RegionOfInterest.encode(roi)
      assert byte_size(encoded) == 17
      assert binary_part(encoded, 16, 1) == <<1>>
    end

    test "round-trips" do
      roi = %RegionOfInterest{
        x_offset: 7,
        y_offset: 9,
        height: 11,
        width: 13,
        do_rectify: true
      }

      assert {:ok, parsed, <<>>} = RegionOfInterest.parse(RegionOfInterest.encode(roi))
      assert parsed == roi
    end
  end

  describe "stereo_msgs/DisparityImage" do
    defp disparity_image(frame_id) do
      %DisparityImage{
        header: header(frame_id),
        image: %Image{
          header: header(frame_id),
          height: 480,
          width: 640,
          encoding: "32FC1",
          is_bigendian: 0,
          step: 2560,
          data: @data
        },
        f: @focal,
        t: @baseline,
        valid_window: %RegionOfInterest{x_offset: 1, y_offset: 2, height: 3, width: 4},
        min_disparity: 0.0,
        max_disparity: 63.0,
        delta_d: @delta_d
      }
    end

    for len <- @frame_id_lengths do
      # `Image` ends in a byte sequence (alignment 1) and
      # `RegionOfInterest` ends in a bool, so both leave the tail at an
      # arbitrary offset — the float32s after them need explicit
      # `align_to(4)`.
      test "f follows the nested Image 4-aligned with a #{len}-char frame_id" do
        encoded = DisparityImage.encode(disparity_image(frame_id(unquote(len))))
        assert_aligned!(encoded, <<@focal::little-float-size(32)>>, 4, "f")
      end

      test "delta_d follows valid_window 4-aligned with a #{len}-char frame_id" do
        encoded = DisparityImage.encode(disparity_image(frame_id(unquote(len))))
        assert_aligned!(encoded, <<@delta_d::little-float-size(32)>>, 4, "delta_d")
      end
    end
  end
end
