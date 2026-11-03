defmodule VisionCore.Detection.LiveTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.Live
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair

  defp pair do
    frame = %Frame{label: "left", width: 960, height: 540, capture_ns: 0, grey: <<>>}
    %Pair{left_frame: frame, right_frame: frame, geometry: %{width: 480, height: 270}}
  end

  # As the detection pipeline places it: its outline on the captured frame, in its pixels.
  defp person(x0, y0, x1, y1, z) do
    %{
      label: "person",
      score: 0.62,
      z: z,
      outline: [
        {x0 / 1.0, y0 / 1.0},
        {x1 / 1.0, y0 / 1.0},
        {x1 / 1.0, y1 / 1.0},
        {x0 / 1.0, y1 / 1.0}
      ]
    }
  end

  defp subscriber_count, do: map_size(:sys.get_state(Live).subscribers)

  defp cast_detections(positioned), do: GenServer.cast(Live, {:detections, pair(), positioned})

  setup do
    start_supervised!({Live, max_hz: 1_000})
    :ok
  end

  test "takes the results the detection pipeline publishes" do
    :ok = Live.subscribe()
    positioned = [person(240, 108, 720, 432, 1.8)]

    Outputs.publish(
      {:detections, VisionCore.Detection.Pipeline},
      {:detections, pair(), positioned}
    )

    assert_receive {:vision_detections, [%{label: "person", distance_m: 1.8}]}
  end

  test "sends each result to subscribers: label, score, distance and outline as fractions of the frame" do
    :ok = Live.subscribe()
    cast_detections([person(240, 108, 720, 432, 1.8)])

    assert_receive {:vision_detections, [detection]}

    assert %{label: "person", score: 0.62, distance_m: 1.8} = detection
    assert detection.outline == [[0.25, 0.2], [0.75, 0.2], [0.75, 0.8], [0.25, 0.8]]
  end

  test "sends an empty result, so boxes from the last one go away" do
    :ok = Live.subscribe()
    cast_detections([person(240, 108, 720, 432, 1.8)])
    assert_receive {:vision_detections, [_detection]}

    cast_detections([])
    assert_receive {:vision_detections, []}
  end

  test "sends at most :max_hz results a second, then the latest one held meanwhile" do
    stop_supervised!(Live)
    start_supervised!({Live, max_hz: 4})
    :ok = Live.subscribe()

    cast_detections([person(240, 108, 720, 432, 1.8)])
    cast_detections([person(240, 108, 720, 432, 2.5)])
    cast_detections([])

    assert_receive {:vision_detections, [_detection]}
    refute_receive {:vision_detections, _}, 150
    assert_receive {:vision_detections, []}, 300
    refute_receive {:vision_detections, _}, 300
  end

  test "counts a process that subscribes twice once" do
    subscriber =
      spawn(fn ->
        Live.subscribe()
        Live.subscribe()
        Process.sleep(:infinity)
      end)

    Process.sleep(50)
    assert subscriber_count() == 1
    assert {:monitors, [{:process, ^subscriber}]} = Process.info(Process.whereis(Live), :monitors)
    Process.exit(subscriber, :kill)
    Process.sleep(50)
    assert subscriber_count() == 0
  end

  test "forgets a subscriber that exits" do
    subscriber = spawn(fn -> Live.subscribe() && Process.sleep(:infinity) end)
    Process.sleep(50)
    assert subscriber_count() == 1

    Process.exit(subscriber, :kill)
    Process.sleep(50)
    assert subscriber_count() == 0
  end
end
