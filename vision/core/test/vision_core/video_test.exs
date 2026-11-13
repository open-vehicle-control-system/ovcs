defmodule VisionCore.VideoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.{Frame, V4L2Single}
  alias VisionCore.{Outputs, Video}

  @config %VisionCore.Config{
    components: [
      {:camera,
       name: :hq,
       driver: V4L2Single,
       csiphy: 2,
       outputs: [
         view: [resolution: {2028, 1520}, processor: :cpu, send: false],
         view_h264: [from: :view, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30],
         view_jpeg: [from: :view, format: :jpeg]
       ]}
    ]
  }

  defp frame(capture_ns, keyframe?) do
    %Frame{
      label: "hq",
      output: :view_h264,
      width: 2028,
      height: 1520,
      capture_ns: capture_ns,
      h264: <<capture_ns::32>>,
      keyframe?: keyframe?
    }
  end

  defp publish(capture_ns, keyframe? \\ false),
    do:
      Outputs.publish(
        {:camera_frame, V4L2Single.name_for("hq"), :view_h264},
        {:camera_frame, frame(capture_ns, keyframe?)}
      )

  defp start_video(opts \\ []),
    do:
      start_supervised!({Video, Keyword.merge([config: @config, videos: [hq: :view_h264]], opts)})

  defp received do
    receive do
      {:vision_video, :hq, %Frame{capture_ns: capture_ns}} -> [capture_ns | received()]
    after
      100 -> []
    end
  end

  test "sends a subscriber every frame of the camera's video, in order, from the next key frame" do
    video = start_video()
    :ok = Video.subscribe(:hq)

    publish(1)
    publish(2, true)
    publish(3)
    :sys.get_state(video)

    assert received() == [2, 3]
  end

  test "lists the videos it relays" do
    start_video()
    assert Video.videos() == [hq: :view_h264]
  end

  test "refuses a subscriber to a camera whose video it does not relay" do
    start_video()
    assert Video.subscribe(:front) == {:error, :unknown_video}
  end

  test "sends at most :in_flight_frames unacknowledged frames, queueing the others in order" do
    video = start_video(in_flight_frames: 2)
    :ok = Video.subscribe(:hq)

    publish(1, true)
    for capture_ns <- 2..4, do: publish(capture_ns)
    :sys.get_state(video)
    assert received() == [1, 2]

    Video.ack(:hq)
    :sys.get_state(video)
    assert received() == [3]

    Video.ack(:hq)
    Video.ack(:hq)
    :sys.get_state(video)
    assert received() == [4]
  end

  test "a subscriber a whole backlog behind skips to the next key frame" do
    video = start_video(in_flight_frames: 1, backlog_frames: 3)
    :ok = Video.subscribe(:hq)

    publish(1, true)
    for capture_ns <- 2..10, do: publish(capture_ns)
    publish(11, true)
    publish(12)
    :sys.get_state(video)
    assert received() == [1]

    Video.ack(:hq)
    :sys.get_state(video)
    assert received() == [11]

    Video.ack(:hq)
    :sys.get_state(video)
    assert received() == [12]
  end

  test "an output that is no H.264 output of the camera is logged and not relayed" do
    log =
      capture_log(fn ->
        start_video(videos: [hq: :view_jpeg])
        assert Video.videos() == []
      end)

    assert log =~ "camera hq has no H.264 output :view_jpeg"
  end
end
