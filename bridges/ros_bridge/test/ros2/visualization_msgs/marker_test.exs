defmodule Ros2.VisualizationMsgs.MarkerTest do
  @moduledoc """
  Regression tests against `test/support/golden_cdr.json`, whose
  bytes were validated by deserialising them with ROS 2 Jazzy — see
  `test/support/golden_cdr.md` for why rclpy's own *serialised* bytes
  cannot be used as a reference, and why matching lengths proves
  nothing here.

  Asserting against recorded bytes rather than a hand-computed length
  is deliberate. Every CDR alignment bug in this codebase so far has
  been a case of confidently predicting an offset and being wrong.
  """
  use ExUnit.Case, async: true

  alias Ros2.BuiltinInterfaces.Msg.{Duration, Time}
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, Quaternion, Vector3}
  alias Ros2.StdMsgs.Msg.{ColorRGBA, Header}
  alias Ros2.VisualizationMsgs.Msg.{Marker, MarkerArray}

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name) do
    @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)
  end

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

  defp cube do
    %Marker{
      header: header(),
      ns: "detections",
      id: 7,
      type: Marker.cube(),
      action: Marker.add(),
      pose: pose(),
      scale: %Vector3{x: 0.4, y: 0.9, z: 0.3},
      color: %ColorRGBA{r: 0.1, g: 0.9, b: 0.2, a: 0.6},
      lifetime: %Duration{sec: 0, nanosec: 200_000_000}
    }
  end

  defp text_marker do
    %{
      cube()
      | id: 8,
        type: Marker.text_view_facing(),
        text: "person 0.91 @ 2.0m",
        scale: %Vector3{x: 0.0, y: 0.0, z: 0.12}
    }
  end

  defp delete_all do
    %Marker{
      header: header(),
      ns: "detections",
      type: 0,
      action: Marker.delete_all(),
      color: %ColorRGBA{r: 0.0, g: 0.0, b: 0.0, a: 0.0}
    }
  end

  describe "Marker.append_to/2 at the body origin" do
    test "a CUBE encodes to the validated bytes" do
      assert Marker.append_to(<<>>, cube()) == golden("marker_cube")
    end

    test "a TEXT_VIEW_FACING marker encodes to the validated bytes" do
      assert Marker.append_to(<<>>, text_marker()) == golden("marker_text")
    end

    test "a DELETEALL marker encodes to the validated bytes" do
      assert Marker.append_to(<<>>, delete_all()) == golden("marker_deleteall")
    end
  end

  describe "MarkerArray.encode/1" do
    test "three markers of differing length encode to the validated bytes" do
      array = %MarkerArray{markers: [delete_all(), cube(), text_marker()]}
      assert MarkerArray.encode(array) == golden("marker_array")
    end

    test "an empty array is just the zero count" do
      assert MarkerArray.encode(%MarkerArray{}) == golden("marker_array_empty")
    end

    # The regression the whole append_to/2 discipline exists for.
    # Encoding each marker from a fresh buffer and concatenating
    # gives every element after the first the padding for offset 0
    # rather than its real offset. Note the naive form is *longer*
    # here, not shorter — which is exactly why length is not the
    # check.
    test "encoding each marker from a fresh buffer would NOT match" do
      markers = [delete_all(), cube(), text_marker()]

      naive =
        Enum.reduce(markers, <<length(markers)::little-unsigned-integer-size(32)>>, fn m, acc ->
          acc <> Marker.append_to(<<>>, m)
        end)

      assert naive != golden("marker_array"),
             "if this passes, the alignment hazard is gone and append_to/2 can be simplified"
    end

    # The concrete numbers behind that hazard, asserted so a future
    # change to Marker cannot quietly move them.
    test "a marker is 4 bytes shorter nested than standalone" do
      standalone = Marker.append_to(<<>>, cube())
      array = MarkerArray.encode(%MarkerArray{markers: [cube()]})

      # Standalone starts at the body origin, so `action` ends at 60
      # and four bytes of padding are needed before `pose`.
      assert byte_size(standalone) == 249

      # Nested, the marker starts at offset 4 (after the count), so
      # `action` ends at 64 and needs none — 245 bytes of content.
      nested_content = byte_size(array) - 4
      assert nested_content == 245
      assert nested_content == byte_size(standalone) - 4
    end
  end
end
