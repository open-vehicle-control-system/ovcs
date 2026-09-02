defmodule Ros2.VisionMsgs.Detection3DTest do
  @moduledoc """
  Regression tests against `test/support/golden_cdr.json`, whose bytes
  were validated by deserialising them with ROS 2 Jazzy. See
  `test/support/golden_cdr.md` for the provenance and for why rclpy's
  serialised bytes are not usable as a byte-equality reference.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion, Vector3}
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.VisionMsgs.Msg.{BoundingBox3D, Detection3D, Detection3DArray}
  alias Ros2.VisionMsgs.Msg.{ObjectHypothesis, ObjectHypothesisWithPose}

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp header do
    %Header{
      stamp: %Time{sec: 1_735_689_600, nanosec: 123_456_789},
      frame_id: "stereo_left_optical"
    }
  end

  defp pose do
    %Pose{
      position: %Point{x: 0.5, y: -0.25, z: 2.0},
      orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}
    }
  end

  defp hypothesis(class_id, score) do
    %ObjectHypothesisWithPose{
      hypothesis: %ObjectHypothesis{class_id: class_id, score: score},
      pose: %PoseWithCovariance{pose: pose()}
    }
  end

  defp detection do
    %Detection3D{
      header: header(),
      results: [hypothesis("person", 0.91)],
      bbox: %BoundingBox3D{center: pose(), size: %Vector3{x: 0.4, y: 0.9, z: 0.3}},
      id: "7"
    }
  end

  defp second_detection do
    %Detection3D{
      header: header(),
      results: [hypothesis("chair", 0.42), hypothesis("person", 0.91)],
      bbox: %BoundingBox3D{center: pose(), size: %Vector3{x: 1.25, y: 0.5, z: 0.75}},
      id: "1234"
    }
  end

  describe "Detection3D.append_to/2" do
    test "encodes to the validated bytes" do
      assert Detection3D.append_to(<<>>, detection()) == golden("detection3d")
    end

    # `id` is the last field, and CDR pads only on behalf of a
    # *following* field's alignment. Using the padded encode_string/1
    # here made every detection two bytes too long.
    test "does not pad the trailing id string" do
      encoded = Detection3D.append_to(<<>>, detection())
      assert byte_size(encoded) == 486
      refute rem(byte_size(encoded), 4) == 0
    end
  end

  describe "Detection3DArray.encode/1" do
    test "a single detection encodes to the validated bytes" do
      array = %Detection3DArray{header: header(), detections: [detection()]}
      assert Detection3DArray.encode(array) == golden("detection3d_array")
    end

    # Two detections with different `id` and `class_id` lengths: the
    # case where a missing align_to/2 between elements shows up.
    test "two detections of differing length encode to the validated bytes" do
      array = %Detection3DArray{
        header: header(),
        detections: [detection(), second_detection()]
      }

      assert Detection3DArray.encode(array) == golden("detection3d_array_two")
    end

    test "an empty array is the header plus a zero count" do
      array = %Detection3DArray{header: header()}
      assert Detection3DArray.encode(array) == golden("detection3d_array_empty")
    end

    test "encoding each detection from a fresh buffer would NOT match" do
      detections = [detection(), second_detection()]

      naive =
        Enum.reduce(
          detections,
          Header.encode(header()) <>
            <<length(detections)::little-unsigned-integer-size(32)>>,
          fn detection, acc -> acc <> Detection3D.append_to(<<>>, detection) end
        )

      assert naive != golden("detection3d_array_two"),
             "if this passes, the alignment hazard is gone and append_to/2 can be simplified"
    end
  end
end
