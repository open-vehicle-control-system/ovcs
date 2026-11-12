defmodule VisionCore.Detection.CameraDepthTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.CameraDepth
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log

  @ms 1_000_000
  @wording %{
    calibration: "none",
    pose: "none",
    unreadable: "none",
    unmatched: "none",
    lens: "project"
  }

  defp depth do
    config = %VisionCore.Config{
      components: [{:camera, [name: :hq, driver: VisionCore.Camera.GStreamer]}]
    }

    CameraDepth.new(:hq, config, "test pipeline", @wording)
  end

  defp pair(capture_ms) do
    frame = %Frame{label: "left", width: 4, height: 2, capture_ns: capture_ms * @ms}

    %Pair{
      left_frame: %Frame{frame | frame_id: "stereo_left_optical"},
      right_frame: %Frame{frame | label: "right"},
      depth: :binary.copy(<<2000::little-16>>, 8),
      geometry: %{principal_point: {2.0, 1.0}, focal_length_px: 5.0}
    }
  end

  defp with_pairs(depth, captures_ms),
    do: Enum.reduce(captures_ms, depth, &CameraDepth.add_pair(&2, pair(&1)))

  defp matched_capture_ms(depth, capture_ms) do
    case CameraDepth.match(depth, capture_ms * @ms, final: true) do
      {:ok, pair} -> div(Pair.capture_ns(pair), @ms)
      :none -> :none
    end
  end

  describe "match/3" do
    test "takes the pair period as the median spacing, the middle two's mean for an even count" do
      depth = with_pairs(depth(), [0, 100, 300])

      assert matched_capture_ms(depth, 370) == 300
      assert matched_capture_ms(depth, 380) == :none
    end
  end
end
