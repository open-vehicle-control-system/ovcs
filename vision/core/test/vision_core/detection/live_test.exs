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

  test "answers while it computes a calibration's map, and draws with it once ready" do
    calibration =
      VisionCore.Ros2.CameraCalibration.load!(
        Path.expand("../../support/calibration/distorted_left.yaml", __DIR__)
      )

    {width, height} = {calibration.width, calibration.height}
    frame = %Frame{label: "left", width: width, height: height, capture_ns: 0, grey: <<>>}

    pair = %Pair{
      left_frame: frame,
      right_frame: frame,
      geometry: %{width: width, height: height, left_calibration: calibration}
    }

    box = %{x0: width * 0.25, y0: height * 0.2, x1: width * 0.75, y1: height * 0.8}
    :ok = Live.subscribe()
    GenServer.cast(Live, {:detections, pair, [%{label: "person", score: 0.6, z: 2.0, box: box}]})

    assert {elapsed_us, 1} = :timer.tc(&Live.subscriber_count/0)
    assert elapsed_us < 50_000
    assert_receive {:vision_detections, [%{outline: scaled}]}
    assert [x, y] = hd(scaled)
    assert_in_delta x, 0.25, 1.0e-9
    assert_in_delta y, 0.2, 1.0e-9

    mapped =
      Enum.find_value(1..100, fn _attempt ->
        Process.sleep(50)

        GenServer.cast(
          Live,
          {:detections, pair, [%{label: "person", score: 0.6, z: 2.0, box: box}]}
        )

        assert_receive {:vision_detections, [%{outline: outline}]}
        if outline != scaled, do: outline
      end)

    assert mapped, "the outline was never mapped through the calibration"
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
