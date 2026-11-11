defmodule Ros2Zenoh.VisionMsgs.Detection2DTest do
  @moduledoc """
  Regression tests against `test/support/golden_cdr.json`, whose bytes
  were validated by deserialising them with ROS 2; see
  `test/support/golden_cdr.md`.
  """
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.VisionMsgs.Msg.{BoundingBox2D, Detection2D, Detection2DArray}
  alias Ros2Zenoh.VisionMsgs.Msg.{ObjectHypothesis, ObjectHypothesisWithPose, Point2D, Pose2D}

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp header do
    %Header{stamp: %Time{sec: 1_735_689_600, nanosec: 123_456_789}, frame_id: "hq_optical"}
  end

  defp detection(class_id, score, {x, y}, {width, height}, id) do
    %Detection2D{
      header: header(),
      results: [
        %ObjectHypothesisWithPose{hypothesis: %ObjectHypothesis{class_id: class_id, score: score}}
      ],
      bbox: %BoundingBox2D{
        center: %Pose2D{position: %Point2D{x: x, y: y}, theta: 0.0},
        size_x: width,
        size_y: height
      },
      id: id
    }
  end

  defp person, do: detection("person", 0.91, {320.5, 240.25}, {80.0, 200.0}, "7")
  defp light, do: detection("traffic_light", 0.42, {12.0, 900.75}, {10.5, 30.0}, "1234")

  test "a detection encodes to the validated bytes" do
    assert Detection2D.append_to(<<>>, person()) == golden("detection2d")
  end

  # Differing `id` and `class_id` lengths: where a missing re-alignment between elements shows up.
  test "two detections of differing length encode to the validated bytes" do
    array = %Detection2DArray{header: header(), detections: [person(), light()]}

    assert Detection2DArray.encode(array) == golden("detection2d_array_two")
  end

  test "an empty array is the header plus a zero count" do
    assert Detection2DArray.encode(%Detection2DArray{header: header()}) ==
             golden("detection2d_array_empty")
  end
end
