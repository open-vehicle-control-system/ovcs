defmodule VisionCore.Detection.LiveTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.Live
  alias VisionCore.Stereo.Pair

  # Matched at half the camera's size, with no calibration, so outlines only scale.
  defp pair do
    frame = %Frame{label: "left", width: 960, height: 540, capture_ns: 0, grey: <<>>}

    %Pair{
      left_frame: frame,
      right_frame: frame,
      geometry: %{width: 480, height: 270, left_calibration: nil}
    }
  end

  defp person(x0, y0, x1, y1, z) do
    %{
      label: "person",
      score: 0.62,
      z: z,
      box: %{x0: x0 / 1.0, y0: y0 / 1.0, x1: x1 / 1.0, y1: y1 / 1.0}
    }
  end

  defp results(positioned), do: GenServer.cast(Live, {:detections, pair(), positioned})

  setup do
    start_supervised!({Live, max_hz: 1_000, outline_segments: 1})
    :ok
  end

  test "sends each result to subscribers: label, score, distance and outline on the raw image" do
    :ok = Live.subscribe()
    results([person(120, 54, 360, 216, 1.8)])

    assert_receive {:vision_detections, [detection]}

    assert %{label: "person", score: 0.62, distance_m: 1.8} = detection
    assert detection.outline == [[0.25, 0.2], [0.75, 0.2], [0.75, 0.8], [0.25, 0.8]]
  end

  test "sends an empty result, so boxes from the last one go away" do
    :ok = Live.subscribe()
    results([person(120, 54, 360, 216, 1.8)])
    assert_receive {:vision_detections, [_detection]}

    results([])
    assert_receive {:vision_detections, []}
  end

  test "sends at most :max_hz results a second, then the latest one held meanwhile" do
    stop_supervised!(Live)
    start_supervised!({Live, max_hz: 4, outline_segments: 1})
    :ok = Live.subscribe()

    results([person(120, 54, 360, 216, 1.8)])
    results([person(120, 54, 360, 216, 2.5)])
    results([])

    assert_receive {:vision_detections, [_detection]}
    refute_receive {:vision_detections, _}, 150
    assert_receive {:vision_detections, []}, 300
    refute_receive {:vision_detections, _}, 300
  end

  test "forgets a subscriber that exits" do
    subscriber = spawn(fn -> Live.subscribe() && Process.sleep(:infinity) end)
    Process.sleep(50)
    assert Live.subscriber_count() == 1

    Process.exit(subscriber, :kill)
    Process.sleep(50)
    assert Live.subscriber_count() == 0
  end
end
