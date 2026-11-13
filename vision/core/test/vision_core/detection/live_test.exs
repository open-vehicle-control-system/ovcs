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

  defp subscriber_count,
    do: map_size(:sys.get_state(VisionCore.Pipelines.server(Live, :detection)).subscribers)

  defp cast_detections(positioned),
    do:
      GenServer.cast(
        VisionCore.Pipelines.server(Live, :detection),
        {{:detections, :detection}, {pair(), positioned}}
      )

  setup do
    start_supervised!({Live, max_hz: 1_000})
    :ok
  end

  test "answers the most results it sends a subscriber a second" do
    assert Live.max_hz() == 1_000
  end

  test "takes the results the detection pipeline publishes" do
    :ok = Live.subscribe()
    positioned = [person(240, 108, 720, 432, 1.8)]

    Outputs.publish(
      {:detections, :detection},
      {{:detections, :detection}, {pair(), positioned}}
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

  test "a camera source's result: its outline as fractions of the camera's frame, without a distance where there is none" do
    :ok = Live.subscribe()
    frame = %Frame{label: "hq", width: 1014, height: 760, capture_ns: 0, rgb: <<>>}

    GenServer.cast(
      VisionCore.Pipelines.server(Live, :detection),
      {{:detections, :hq_people}, {frame, [person(0, 0, 507, 380, nil)]}}
    )

    assert_receive {:vision_detections, [%{distance_m: nil, outline: outline}]}
    assert outline == [[0.0, 0.0], [0.5, 0.0], [0.5, 0.5], [0.0, 0.5]]
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

    assert {:monitors, [{:process, ^subscriber}]} =
             Process.info(
               GenServer.whereis(VisionCore.Pipelines.server(Live, :detection)),
               :monitors
             )

    Process.exit(subscriber, :kill)
    Process.sleep(50)
    assert subscriber_count() == 0
  end

  describe "a named pipeline's" do
    setup do
      start_supervised!(Supervisor.child_spec({Live, name: :road, max_hz: 5}, id: :road_live))
      :ok
    end

    test "answers its own :max_hz" do
      assert Live.max_hz(:road) == 5
      assert Live.max_hz() == 1_000
    end

    test "sends its subscribers that pipeline's results only, and the default's never reach them" do
      road_subscriber = self()

      spawn_link(fn ->
        :ok = Live.subscribe(:road)
        send(road_subscriber, :subscribed)

        receive do: ({:vision_detections, detections} ->
                       send(road_subscriber, {:road, detections}))
      end)

      assert_receive :subscribed
      :ok = Live.subscribe()

      Outputs.publish(
        {:detections, :road},
        {{:detections, :road}, {pair(), [person(240, 108, 720, 432, 3.0)]}}
      )

      assert_receive {:road, [%{distance_m: 3.0}]}
      refute_receive {:vision_detections, _detections}, 100

      Outputs.publish(
        {:detections, :detection},
        {{:detections, :detection}, {pair(), [person(240, 108, 720, 432, 1.8)]}}
      )

      assert_receive {:vision_detections, [%{distance_m: 1.8}]}
      refute_receive {:road, _detections}, 100
    end
  end

  test "forgets a subscriber that exits" do
    subscriber = spawn(fn -> Live.subscribe() && Process.sleep(:infinity) end)
    Process.sleep(50)
    assert subscriber_count() == 1

    Process.exit(subscriber, :kill)
    Process.sleep(50)
    assert subscriber_count() == 0
  end

  test "refuses a :max_hz that is no integer from 1 on" do
    Process.flag(:trap_exit, true)

    for max_hz <- [0, 2.5, nil] do
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Live.start_link(name: :road, max_hz: max_hz)

      assert message == "its :max_hz is an integer from 1 on, got #{inspect(max_hz)}"
    end
  end
end
