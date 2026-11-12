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

  defp depth(pair_wait_ms \\ 500) do
    config = %VisionCore.Config{
      components: [{:camera, [name: :hq, driver: VisionCore.Camera.GStreamer]}]
    }

    CameraDepth.new(:hq, config, "test pipeline", @wording, pair_wait_ms: pair_wait_ms)
  end

  defp pair(capture_ms) do
    frame = %Frame{
      label: "left",
      width: 4,
      height: 2,
      capture_ns: capture_ms * @ms,
      grey: :binary.copy(<<0>>, 8)
    }

    %Pair{
      left_frame: %Frame{frame | frame_id: "stereo_left_optical"},
      right_frame: %Frame{frame | label: "right"},
      left: Nx.broadcast(Nx.u8(0), {2, 4}),
      right: Nx.broadcast(Nx.u8(0), {2, 4}),
      disparity: Nx.broadcast(Nx.f32(1), {2, 4}),
      disparity_bytes: :binary.copy(<<0>>, 32),
      cloud: :binary.copy(<<0>>, 96),
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

    test "keeps the pairs captured within pair_wait_ms of the newest one" do
      depth = with_pairs(depth(500), Enum.to_list(0..1000//100))

      assert matched_capture_ms(depth, 500) == 500
      assert matched_capture_ms(depth, 400) == :none
    end

    test "keeps two pairs however far apart, for their period" do
      depth = with_pairs(depth(50), [0, 1000])

      assert matched_capture_ms(depth, 100) == 0
    end

    test "gives a kept pair's depth, size and left frame, without its images" do
      depth = with_pairs(depth(), [0, 100])

      assert {:ok, kept} = CameraDepth.match(depth, 100 * @ms)
      assert kept.depth == pair(100).depth
      assert Pair.size(kept) == {4, 2}
      assert Pair.frame_id(kept) == "stereo_left_optical"
      assert %{principal_point: {2.0, 1.0}, focal_length_px: 5.0} = kept.geometry
      assert %Frame{grey: nil, rgb: nil, jpeg: nil} = kept.left_frame
      assert %{left: nil, right: nil, right_frame: nil, disparity: nil, cloud: nil} = kept
      assert kept.disparity_bytes == nil
    end

    test "keeps a depth map cut out of a larger binary without the rest of it" do
      reply = :binary.copy(<<2000::little-16>>, 1_000)
      pair = %{pair(100) | depth: binary_part(reply, 0, 400)}
      depth = CameraDepth.add_pair(with_pairs(depth(), [0]), pair, 100 * @ms)

      assert {:ok, kept} = CameraDepth.match(depth, 100 * @ms)
      assert kept.depth == binary_part(reply, 0, 400)
      assert :binary.referenced_byte_size(kept.depth) == 400
    end
  end
end
