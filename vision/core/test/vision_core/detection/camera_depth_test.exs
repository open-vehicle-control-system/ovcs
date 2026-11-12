defmodule VisionCore.Detection.CameraDepthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  @calibration Path.expand("../../support/calibration", __DIR__)

  # A camera with a calibration and a pose, or with `files` of them only.
  defp depth(pair_wait_ms \\ 500, files \\ [:calibration, :pose]) do
    paths = [
      calibration: Path.join(@calibration, "equidistant_hq.yaml"),
      pose: Path.join(@calibration, "camera_pose_hq.yaml")
    ]

    camera = [name: :hq, driver: VisionCore.Camera.GStreamer] ++ Keyword.take(paths, files)
    config = %VisionCore.Config{components: [{:camera, camera}]}
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

  # Each pair arriving as it is captured.
  defp with_pairs(depth, captures_ms),
    do: Enum.reduce(captures_ms, depth, &CameraDepth.add_pair(&2, pair(&1), &1 * @ms))

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

    test "keeps a depth map that is a binary of its own as it is" do
      own = :binary.copy(<<2000::little-16>>, 1_000)
      pair = %{pair(100) | depth: own}
      depth = CameraDepth.add_pair(with_pairs(depth(), [0]), pair, 100 * @ms)

      assert {:ok, kept} = CameraDepth.match(depth, 100 * @ms)
      assert :erts_debug.same(kept.depth, own)
    end

    test "keeps no pair for a camera it cannot project into" do
      for files <- [[:calibration], [:pose]] do
        depth = with_pairs(depth(500, files), [0, 100])

        assert CameraDepth.match(depth, 100 * @ms, final: true) == :none
      end
    end
  end

  describe "new/5" do
    @tag :tmp_dir
    test "refuses a calibration it cannot project with at start, saying so once", %{tmp_dir: dir} do
      calibration = %VisionCore.Ros2.CameraCalibration{
        width: 40,
        height: 20,
        distortion_model: "rational_polynomial",
        distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        camera_matrix: [50.0, 0.0, 20.0, 0.0, 50.0, 10.0, 0.0, 0.0, 1.0],
        rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        projection_matrix: [50.0, 0.0, 20.0, 0.0, 0.0, 50.0, 10.0, 0.0, 0.0, 0.0, 1.0, 0.0]
      }

      path = Path.join(dir, "hq.yaml")
      File.write!(path, VisionCore.Ros2.CameraCalibration.to_yaml(calibration, "hq"))

      config = %VisionCore.Config{
        components: [
          {:camera, [name: :hq, driver: VisionCore.Camera.GStreamer, calibration: path]}
        ]
      }

      log =
        capture_log(fn ->
          depth = CameraDepth.new(:hq, config, "test pipeline", @wording, pair_wait_ms: 500)
          assert {nil, _depth} = CameraDepth.lens(depth, {40, 20})
        end)

      assert [_once] = Regex.scan(~r/rational_polynomial/, log)
      assert log =~ "test pipeline: camera hq's calibration cannot project"
    end
  end

  describe "lens/2" do
    @tag :tmp_dir
    test "has none for frames of another aspect ratio than the calibration's, saying so once",
         %{tmp_dir: dir} do
      calibration = %VisionCore.Ros2.CameraCalibration{
        width: 80,
        height: 40,
        distortion_model: "plumb_bob",
        distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0],
        camera_matrix: [100.0, 0.0, 40.0, 0.0, 100.0, 20.0, 0.0, 0.0, 1.0],
        rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        projection_matrix: [100.0, 0.0, 40.0, 0.0, 0.0, 100.0, 20.0, 0.0, 0.0, 0.0, 1.0, 0.0]
      }

      path = Path.join(dir, "hq.yaml")
      File.write!(path, VisionCore.Ros2.CameraCalibration.to_yaml(calibration, "hq"))

      config = %VisionCore.Config{
        components: [
          {:camera, [name: :hq, driver: VisionCore.Camera.GStreamer, calibration: path]}
        ]
      }

      depth = CameraDepth.new(:hq, config, "test pipeline", @wording, pair_wait_ms: 500)
      assert {lens, depth} = CameraDepth.lens(depth, {40, 20})
      refute is_nil(lens)

      log =
        capture_log(fn ->
          assert {nil, depth} = CameraDepth.lens(depth, {40, 30})
          assert {nil, _depth} = CameraDepth.lens(depth, {40, 30})
        end)

      assert [_once] = Regex.scan(~r/camera hq: its 80x40 calibration .* 40x30/, log)
    end
  end

  describe "stalled?/2" do
    test "is stalled before two pairs came" do
      refute CameraDepth.stalled?(with_pairs(depth(), [0, 100]), 100 * @ms)
      assert CameraDepth.stalled?(with_pairs(depth(), [0]), 0)
      assert CameraDepth.stalled?(depth(), 0)
    end

    test "is stalled once no pair came for two pair periods, by arrival time" do
      depth =
        depth()
        |> CameraDepth.add_pair(pair(0), 5_000 * @ms)
        |> CameraDepth.add_pair(pair(100), 5_100 * @ms)

      refute CameraDepth.stalled?(depth, 5_300 * @ms)
      assert CameraDepth.stalled?(depth, 5_300 * @ms + 1)
    end

    test "keeps only the pair captured two pair periods after the one before" do
      depth =
        with_pairs(depth(60_000), [0, 100])
        |> CameraDepth.add_pair(pair(2_000), 2_000 * @ms)

      assert CameraDepth.stalled?(depth, 2_000 * @ms)
      assert matched_capture_ms(depth, 1_600) == :none

      depth = CameraDepth.add_pair(depth, pair(2_100), 2_100 * @ms)

      refute CameraDepth.stalled?(depth, 2_100 * @ms)
      assert matched_capture_ms(depth, 2_040) == 2_000
      assert matched_capture_ms(depth, 1_900) == :none
    end

    test "keeps the pairs before a pair captured on time, however late it is handled" do
      depth =
        with_pairs(depth(60_000), [0, 100])
        |> CameraDepth.add_pair(pair(200), 1_000 * @ms)

      refute CameraDepth.stalled?(depth, 1_000 * @ms)
      assert matched_capture_ms(depth, 160) == 200
      assert matched_capture_ms(depth, 140) == 100
    end
  end

  describe "add_queued_pairs/2" do
    test "keeps the stereo pairs waiting in the mailbox, and leaves every other message" do
      depth = with_pairs(depth(60_000), [0])

      for capture_ms <- [100, 200], do: GenServer.cast(self(), {:stereo_pair, pair(capture_ms)})
      send(self(), :other)

      depth = CameraDepth.add_queued_pairs(depth, 200 * @ms)

      assert matched_capture_ms(depth, 190) == 200
      refute_received {:"$gen_cast", {:stereo_pair, _pair}}
      assert_received :other
    end
  end
end
