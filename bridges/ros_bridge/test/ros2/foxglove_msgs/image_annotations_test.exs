defmodule Ros2.FoxgloveMsgs.ImageAnnotationsTest do
  @moduledoc """
  Byte-equality against `test/support/golden_cdr.json` for the
  annotation overlay — `<prefix>/left/detections`, the labelled boxes
  Foxglove draws on the camera image.

  These encoders had no tests, and they are the most
  alignment-dependent in the tree: `TextAnnotation` puts a string
  immediately before a `float64`, and `PointsAnnotation` puts a `uint8`
  before a `uint32` sequence count before a run of `float64` pairs.
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

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.FoxgloveMsgs.Msg.Color
  alias Ros2.FoxgloveMsgs.Msg.ImageAnnotations
  alias Ros2.FoxgloveMsgs.Msg.Point2
  alias Ros2.FoxgloveMsgs.Msg.PointsAnnotation
  alias Ros2.FoxgloveMsgs.Msg.TextAnnotation

  @golden __DIR__
          |> Path.join("../../support/golden_cdr.json")
          |> Path.expand()
          |> File.read!()
          |> Jason.decode!()

  defp golden(name), do: @golden |> Map.fetch!(name) |> Base.decode16!(case: :lower)

  defp stamp, do: %Time{sec: 1_735_689_600, nanosec: 123_456_789}

  defp text(body) do
    %TextAnnotation{
      timestamp: stamp(),
      position: %Point2{x: 12.5, y: 34.25},
      text: body,
      font_size: 14.0,
      text_color: %Color{r: 1.0, g: 0.5, b: 0.25, a: 1.0},
      background_color: %Color{r: 0.0, g: 0.0, b: 0.0, a: 0.5},
      metadata: []
    }
  end

  defp points(pts, colours) do
    %PointsAnnotation{
      timestamp: stamp(),
      type: 2,
      points: pts,
      outline_color: %Color{r: 1.0, g: 0.0, b: 0.0, a: 1.0},
      outline_colors: colours,
      fill_color: %Color{r: 0.0, g: 1.0, b: 0.0, a: 0.25},
      thickness: 2.5,
      metadata: []
    }
  end

  defp pt(x, y), do: %Point2{x: x, y: y}

  describe "TextAnnotation" do
    # 11 and 12 characters, either side of an 8-residue. A string pads
    # its tail to 4, so whether the following float64 needs 0 or 4 more
    # bytes depends on the label's length — and detection labels vary
    # in length by nature ("car 0.64" vs "bicycle 0.77").
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
      # 11 chars + NUL = 12, already a multiple of 4, so `encode_string`
      # adds nothing and the following `align_to(8)` adds 4.
      # 12 chars + NUL = 13, which `encode_string` pads to 16, and then
      # `align_to(8)` adds nothing. Net: 4 more in the string field and
      # 4 fewer in padding would cancel — except the string field grew
      # by 4 *and* the run now starts 8 further on, so the message is 8
      # bytes longer for one extra character.
      #
      # That non-linearity is the hazard in one assertion: anything
      # assuming length tracks character count is wrong here.
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
          points: [points([pt(1.0, 2.0), pt(3.0, 4.0), pt(5.0, 6.5)], [])]
        })

      assert encoded == golden("fox_points")
    end

    test "an empty points sequence carries no padding" do
      # Fast-CDR's serialize_array returns before aligning when the
      # element count is zero, so an empty sequence is just its length
      # prefix. The encoder has a separate clause for this; without it
      # a real peer would read every following field shifted by 4.
      encoded =
        ImageAnnotations.encode(%ImageAnnotations{timestamp: stamp(), points: [points([], [])]})

      assert encoded == golden("fox_points_empty")
    end

    test "the empty case is shorter by exactly the points, with no padding either side" do
      populated = byte_size(golden("fox_points"))
      empty = byte_size(golden("fox_points_empty"))
      # 3 points x 2 float64 = 48 bytes. The difference is exactly that,
      # which says the count landed already 8-aligned here so the
      # populated case needed no padding — and the empty case added
      # none, which is the behaviour under test. A difference of 52
      # would mean the empty sequence was correct and the populated one
      # padded; 44 would mean the reverse.
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
            points([pt(1.0, 2.0), pt(3.0, 4.0)], [%Color{r: 1.0, g: 1.0, b: 0.0, a: 1.0}])
          ],
          texts: [text("car 0.64")]
        })

      assert encoded == golden("fox_mixed")
    end
  end
end
