defmodule Ros2.SensorMsgs.Msg.CameraInfoTest do
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.SensorMsgs.Msg.CameraInfo
  alias Ros2.SensorMsgs.Msg.RegionOfInterest
  alias Ros2.SensorMsgs.Srv.SetCameraInfo
  alias Ros2.StdMsgs.Msg.Header

  # `D` is the only unbounded float64[] in the message, and it is the
  # one field whose padding depends on the offset it lands at. The
  # distinctive first element lets us locate the start of the float
  # run in the raw bytes without going through our own parser — a
  # round-trip alone would not catch a symmetric encoder/parser bug,
  # which is exactly what this guards against.
  @d_first 1.5
  @d [1.5, 2.5, 3.5, 4.5, 5.5]

  defp sample(frame_id, d) do
    %CameraInfo{
      header: %Header{
        stamp: %Time{sec: 1_700_000_000, nanosec: 123_456_789},
        frame_id: frame_id
      },
      height: 480,
      width: 640,
      distortion_model: "plumb_bob",
      d: d,
      k: List.duplicate(0.0, 9),
      r: List.duplicate(0.0, 9),
      p: List.duplicate(0.0, 12),
      binning_x: 0,
      binning_y: 0,
      roi: %RegionOfInterest{}
    }
  end

  describe "D alignment" do
    # CDR aligns a float64 run to 8 bytes from the body origin. A
    # frame_id one character longer moves the length prefix between
    # the two 8-residues, so any fixed padding is wrong for half of
    # these names.
    for len <- 8..16 do
      test "first D float is 8-aligned with a #{len}-char frame_id" do
        frame_id = String.duplicate("x", unquote(len))
        encoded = CameraInfo.encode(sample(frame_id, @d))
        needle = <<@d_first::little-float-size(64)>>

        offset =
          case :binary.match(encoded, needle) do
            {offset, 8} -> offset
            :nomatch -> flunk("could not locate the start of D in the encoded body")
          end

        assert rem(offset, 8) == 0,
               "D starts at offset #{offset}, which is #{rem(offset, 8)} bytes past an 8-boundary"
      end
    end
  end

  describe "round trip" do
    for len <- 8..16 do
      test "survives a #{len}-char frame_id with a populated D" do
        message = sample(String.duplicate("x", unquote(len)), @d)
        assert {:ok, parsed, <<>>} = CameraInfo.parse(CameraInfo.encode(message))
        assert parsed == message
      end

      # Fast-CDR's serialize_array returns before aligning when the
      # element count is 0, so an empty D is just its length prefix
      # with no padding at all.
      test "survives a #{len}-char frame_id with an empty D" do
        message = sample(String.duplicate("x", unquote(len)), [])
        assert {:ok, parsed, <<>>} = CameraInfo.parse(CameraInfo.encode(message))
        assert parsed == message
        assert parsed.d == []
      end
    end

    test "carries D values through unchanged" do
      message = sample("stereo_right", @d)
      assert {:ok, parsed, <<>>} = CameraInfo.parse(CameraInfo.encode(message))
      assert parsed.d == @d
      assert parsed.k == message.k
      assert parsed.p == message.p
    end
  end

  describe "SetCameraInfo request" do
    # The calibration COMMIT path: cameracalibrator sends a request
    # wrapping a CameraInfo, and the server persists whatever it
    # parses. A misparse here writes shifted matrices to the vehicle's
    # calibration YAML while still replying success.
    for frame_id <- ["stereo_left", "stereo_right"] do
      test "parses a request for #{frame_id}" do
        message = sample(unquote(frame_id), @d)

        assert {:ok, request, <<>>} =
                 SetCameraInfo.Request.parse(CameraInfo.encode(message))

        assert request.camera_info == message
      end
    end
  end

  describe "golden bytes" do
    # Byte-equality against `test/support/golden_cdr.json`, whose bytes
    # were validated by deserialising them with ROS 2 — see
    # `test/support/golden_cdr.md`. The alignment tests above prove the
    # float run lands on an 8-boundary by our own arithmetic; these
    # prove the whole encoding is what a real ROS peer reads back.
    #
    # `stereo_right` (12 chars) and `stereo_left` (11) are both here on
    # purpose: they fall either side of an 8-residue, so the D length
    # prefix needs 0 bytes of padding for one and 4 for the other. The
    # original fixed-padding encoder got exactly one of them right.
    @golden __DIR__
            |> Path.join("../../../support/golden_cdr.json")
            |> Path.expand()
            |> File.read!()
            |> Jason.decode!()

    defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

    defp golden_camera_info(frame_id, d) do
      %CameraInfo{
        header: %Header{
          stamp: %Time{sec: 1_735_689_600, nanosec: 123_456_789},
          frame_id: frame_id
        },
        height: 270,
        width: 480,
        distortion_model: "plumb_bob",
        d: d,
        k: [321.5, 0.0, 240.25, 0.0, 321.5, 135.75, 0.0, 0.0, 1.0],
        r: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        p: [321.5, 0.0, 240.25, -19.29, 0.0, 321.5, 135.75, 0.0, 0.0, 0.0, 1.0, 0.0],
        binning_x: 0,
        binning_y: 0,
        roi: %RegionOfInterest{
          x_offset: 8,
          y_offset: 4,
          height: 262,
          width: 464,
          do_rectify: false
        }
      }
    end

    @distortion [-0.17, 0.028, 0.0, 0.0, 0.0]

    test "stereo_right (12-char frame_id, no D padding) matches ROS 2" do
      assert CameraInfo.encode(golden_camera_info("stereo_right", @distortion)) ==
               golden("camera_info_right")
    end

    test "stereo_left (11-char frame_id, 4 bytes of D padding) matches ROS 2" do
      assert CameraInfo.encode(golden_camera_info("stereo_left", @distortion)) ==
               golden("camera_info_left")
    end

    test "an empty D carries no padding at all" do
      assert CameraInfo.encode(golden_camera_info("stereo_right", [])) ==
               golden("camera_info_right_empty_d")
    end

    test "the golden bytes round-trip back through our parser" do
      for name <- ["camera_info_right", "camera_info_left", "camera_info_right_empty_d"] do
        assert {:ok, %CameraInfo{}, <<>>} = CameraInfo.parse(golden(name))
      end
    end
  end
end
