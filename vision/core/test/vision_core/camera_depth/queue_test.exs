defmodule VisionCore.CameraDepth.QueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.CameraDepth
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log

  @ms 1_000_000
  @wording %{
    calibration: "none",
    pose: "none",
    unreadable: "none",
    unmatched: "its results have no depth",
    lens: "project"
  }

  @calibration Path.expand("../../support/calibration", __DIR__)

  defp depth(pair_wait_ms) do
    camera = [
      name: :hq,
      driver: VisionCore.Camera.GStreamer,
      calibration: Path.join(@calibration, "equidistant_hq.yaml"),
      pose: Path.join(@calibration, "camera_pose_hq.yaml")
    ]

    config = %VisionCore.Config{components: [{:camera, camera}]}
    CameraDepth.new(:hq, config, "test pipeline", @wording, pair_wait_ms: pair_wait_ms)
  end

  defp pair(capture_ms) do
    frame = %Frame{label: "left", width: 4, height: 2, capture_ns: capture_ms * @ms}

    %Pair{
      left_frame: frame,
      right_frame: %Frame{frame | label: "right"},
      depth: :binary.copy(<<2000::little-16>>, 8),
      geometry: %{width: 4, height: 2, principal_point: {2.0, 1.0}, focal_length_px: 5.0}
    }
  end

  # A pair arriving at `arrival_ms`, as it is captured by default.
  defp add_pair(depth, capture_ms, arrival_ms \\ nil),
    do: CameraDepth.add_pair(depth, pair(capture_ms), (arrival_ms || capture_ms) * @ms)

  defp settled_captures(queue, depth, now_ms) do
    {settled, queue} = CameraDepth.Queue.settle(queue, depth, now_ms * @ms)

    {Enum.map(settled, fn {result, pair} -> {result, pair && div(Pair.capture_ns(pair), @ms)} end),
     queue}
  end

  test "settles results in capture order, each with its own pair, as late pairs come" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(1_000)

    queue =
      CameraDepth.Queue.new(60_000)
      |> CameraDepth.Queue.put(:first, 1_400 * @ms, 1_450 * @ms)
      |> CameraDepth.Queue.put(:second, 1_900 * @ms, 1_950 * @ms)

    assert {[], queue} = settled_captures(queue, depth, 1_950)

    depth = add_pair(depth, 1_500, 2_000)
    assert {[first: 1_500], queue} = settled_captures(queue, depth, 2_000)

    depth = add_pair(depth, 2_000, 2_500)
    assert {[second: 2_000], _queue} = settled_captures(queue, depth, 2_500)
  end

  test "settles a result that needs no depth once the results before it are" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(1_000)

    queue =
      CameraDepth.Queue.new(60_000)
      |> CameraDepth.Queue.put(:boxes, 1_400 * @ms, 1_400 * @ms)
      |> CameraDepth.Queue.put_without_depth(:no_boxes)

    assert {[], queue} = settled_captures(queue, depth, 1_400)

    assert {[boxes: 1_500, no_boxes: nil], _queue} =
             settled_captures(queue, add_pair(depth, 1_500), 1_500)
  end

  test "settles a result past its deadline with the pairs there are" do
    depth = depth(500) |> add_pair(0) |> add_pair(1_000)
    queue = CameraDepth.Queue.put(CameraDepth.Queue.new(500), :late, 1_600 * @ms, 1_000 * @ms)

    assert {[], queue} = settled_captures(queue, depth, 1_499)
    assert {[late: nil], _queue} = settled_captures(queue, depth, 1_500)
  end

  test "settles at once, without a pair, while the stereo pairs have stalled" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(100)
    queue = CameraDepth.Queue.put(CameraDepth.Queue.new(60_000), :stalled, 250 * @ms, 250 * @ms)

    assert {[], queue} = settled_captures(queue, depth, 299)
    assert {[stalled: nil], _queue} = settled_captures(queue, depth, 300)
  end

  test "settles with a pair kept within half a period while the stereo pairs have stalled" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(100)
    queue = CameraDepth.Queue.put(CameraDepth.Queue.new(60_000), :close, 130 * @ms, 130 * @ms)

    assert {[], queue} = settled_captures(queue, depth, 299)
    assert {[close: 100], _queue} = settled_captures(queue, depth, 300)
  end

  test "settles at once, without a pair, before two pairs came" do
    queue = CameraDepth.Queue.put(CameraDepth.Queue.new(60_000), :alone, 100 * @ms, 100 * @ms)

    assert {[alone: nil], _queue} = settled_captures(queue, depth(60_000), 100)
  end

  test "is full with 32 results waiting, saying so once, and has room again once one is settled" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(1_000)

    queue =
      Enum.reduce(1..32, CameraDepth.Queue.new(60_000), fn index, queue ->
        assert {:ok, queue} = CameraDepth.Queue.admit(queue, depth)
        CameraDepth.Queue.put(queue, index, (1_000 + index) * @ms, 1_000 * @ms)
      end)

    log =
      capture_log(fn ->
        assert {:full, queue} = CameraDepth.Queue.admit(queue, depth)
        assert {:full, _queue} = CameraDepth.Queue.admit(queue, depth)
      end)

    assert [_once] = Regex.scan(~r/32 of the camera hq's images wait/, log)
    {settled, queue} = CameraDepth.Queue.settle(queue, add_pair(depth, 1_100), 1_100 * @ms)
    assert length(settled) == 32
    assert {:ok, _queue} = CameraDepth.Queue.admit(queue, depth)
  end

  test "logs the first result settled without a pair, and again after one with" do
    depth = depth(60_000) |> add_pair(0) |> add_pair(1_000)

    log =
      capture_log(fn ->
        queue =
          CameraDepth.Queue.new(60_000)
          |> CameraDepth.Queue.put(:far, 3_000 * @ms, 1_000 * @ms)
          |> CameraDepth.Queue.put(:farther, 3_100 * @ms, 1_000 * @ms)

        {[far: nil, farther: nil], queue} = settled_captures(queue, depth, 61_000)
        queue = CameraDepth.Queue.put(queue, :close, 1_000 * @ms, 61_000 * @ms)
        {[close: 1_000], queue} = settled_captures(queue, depth, 61_000)
        queue = CameraDepth.Queue.put(queue, :far_again, 3_000 * @ms, 61_000 * @ms)
        {[far_again: nil], _queue} = settled_captures(queue, depth, 121_000)
      end)

    assert [_first, _again] = Regex.scan(~r/so its results have no depth until one is/, log)
  end

  describe "schedule/3" do
    test "has the owner told to settle again at the first result's deadline" do
      now_ns = System.monotonic_time(:nanosecond)

      depth =
        depth(20)
        |> CameraDepth.add_pair(pair(0), now_ns - 1_000 * @ms)
        |> CameraDepth.add_pair(pair(1_000), now_ns)

      CameraDepth.Queue.new(20)
      |> CameraDepth.Queue.put(:waiting, 1_500 * @ms, now_ns)
      |> CameraDepth.Queue.schedule(depth, now_ns)

      assert_receive :pair_wait, 1_000
    end

    test "arms again a timer that fired while the first result still waits" do
      now_ns = System.monotonic_time(:nanosecond)

      depth =
        depth(20)
        |> CameraDepth.add_pair(pair(0), now_ns - 1_000 * @ms)
        |> CameraDepth.add_pair(pair(1_000), now_ns)

      queue =
        CameraDepth.Queue.new(20)
        |> CameraDepth.Queue.put(:waiting, 1_500 * @ms, now_ns)
        |> CameraDepth.Queue.schedule(depth, now_ns)

      assert_receive :pair_wait, 1_000
      CameraDepth.Queue.schedule(queue, depth, now_ns)
      assert_receive :pair_wait, 1_000
    end

    test "has the owner told to settle again when the stereo pairs stall" do
      now_ns = System.monotonic_time(:nanosecond)

      depth =
        depth(60_000)
        |> CameraDepth.add_pair(pair(0), now_ns - 10 * @ms)
        |> CameraDepth.add_pair(pair(10), now_ns)

      CameraDepth.Queue.new(60_000)
      |> CameraDepth.Queue.put(:waiting, 50 * @ms, now_ns)
      |> CameraDepth.Queue.schedule(depth, now_ns)

      assert_receive :pair_wait, 1_000
    end

    test "arms nothing for an empty queue" do
      CameraDepth.Queue.schedule(
        CameraDepth.Queue.new(20),
        depth(20),
        System.monotonic_time(:nanosecond)
      )

      refute_receive :pair_wait, 50
    end
  end
end
