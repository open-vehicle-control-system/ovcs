defmodule Ros2Zenoh.FoxgloveMsgs.ImageAnnotationsTest do
  @moduledoc """
  Byte-equality against `test/support/golden_cdr.json` for the
  annotation overlay — `<prefix>/left/detections`, the labelled boxes
  Foxglove draws on the camera image.

  These are the most alignment-dependent encoders in the tree:
  `TextAnnotation` puts a string immediately before a `float64`, and
  `PointsAnnotation` puts a `uint8` before a `uint32` sequence count
  before a run of `float64` pairs.
  Every one of those boundaries needs explicit padding, and getting one
  wrong shifts every field after it while still producing a message
  that decodes to *something*.

  The vectors were validated by deserialising them with `foxglove_msgs`
  on a real ROS 2 runtime — see `test/support/golden_cdr.md`. That
  matters more here than usual: `foxglove_msgs.Color` is `float64`
  where `std_msgs/ColorRGBA` is `float32`, so a reasonable assumption
  about which one this is would be wrong in a way only a real decoder
  catches.
  """
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.FoxgloveMsgs.Msg.Color
  alias Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2Zenoh.FoxgloveMsgs.Msg.Point2
  alias Ros2Zenoh.FoxgloveMsgs.Msg.PointsAnnotation
  alias Ros2Zenoh.FoxgloveMsgs.Msg.TextAnnotation

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp stamp, do: %Time{sec: 1_735_689_600, nanosec: 123_456_789}

  defp text(label) do
    %TextAnnotation{
      timestamp: stamp(),
      position: %Point2{x: 12.5, y: 34.25},
      text: label,
      font_size: 14.0,
      text_color: %Color{r: 1.0, g: 0.5, b: 0.25, a: 1.0},
      background_color: %Color{r: 0.0, g: 0.0, b: 0.0, a: 0.5},
      metadata: []
    }
  end

  defp points(vertices, outline_colours) do
    %PointsAnnotation{
      timestamp: stamp(),
      type: 2,
      points: vertices,
      outline_color: %Color{r: 1.0, g: 0.0, b: 0.0, a: 1.0},
      outline_colors: outline_colours,
      fill_color: %Color{r: 0.0, g: 1.0, b: 0.0, a: 0.25},
      thickness: 2.5,
      metadata: []
    }
  end

  defp point(x, y), do: %Point2{x: x, y: y}

  describe "TextAnnotation" do
    # 11 and 12 characters, either side of an 8-residue: whether the
    # float64 after the string needs 0 or 4 more bytes depends on the
    # label's length, and detection labels vary in length.
    test "an 11-character label" do
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{
          timestamp: stamp(),
          texts: [text("person 0.91")]
        })

      assert encoded == golden("fox_text_odd")
    end

    test "a 12-character label" do
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{
          timestamp: stamp(),
          texts: [text("bicycle 0.77")]
        })

      assert encoded == golden("fox_text_even")
    end

    test "one more character costs eight bytes, not one" do
      # The string pads to 4 and the float64 after it re-aligns to 8, so
      # one more character moves everything after it by 8: message
      # length does not track character count. See golden_cdr.md.
      odd = byte_size(golden("fox_text_odd"))
      even = byte_size(golden("fox_text_even"))
      assert odd == 144
      assert even == 152
      assert even - odd == 8
    end
  end

  describe "PointsAnnotation" do
    test "a run of points" do
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{
          timestamp: stamp(),
          points: [points([point(1.0, 2.0), point(3.0, 4.0), point(5.0, 6.5)], [])]
        })

      assert encoded == golden("fox_points")
    end

    test "an empty points sequence carries no padding" do
      # Fast-CDR's serialize_array returns before aligning when the
      # element count is zero, so an empty sequence is just its length
      # prefix; padding it would shift every following field by 4.
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{timestamp: stamp(), points: [points([], [])]})

      assert encoded == golden("fox_points_empty")
    end

    test "the empty case is shorter by exactly the points, with no padding either side" do
      populated = byte_size(golden("fox_points"))
      empty = byte_size(golden("fox_points_empty"))
      # 3 points x 2 float64 = 48 bytes: neither case adds padding. 52
      # would mean the populated case padded, 44 the empty one.
      assert populated - empty == 48
    end
  end

  describe "a mixed annotation set" do
    test "points and texts together" do
      # The real shape published per frame: an outline plus its label.
      # Both sequences are non-empty, so both alignment paths are live
      # at once.
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{
          timestamp: stamp(),
          points: [
            points([point(1.0, 2.0), point(3.0, 4.0)], [%Color{r: 1.0, g: 1.0, b: 0.0, a: 1.0}])
          ],
          texts: [text("car 0.64")]
        })

      assert encoded == golden("fox_mixed")
    end
  end
end
