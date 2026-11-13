defmodule VisionApiWeb.VideoChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.{Frame, V4L2Single}

  @config %VisionCore.Config{
    components: [
      {:camera,
       name: :hq,
       driver: V4L2Single,
       csiphy: 2,
       outputs: [
         full: [resolution: {2028, 1520}, processor: :cpu, send: false],
         full_h264: [from: :full, format: :h264, bitrate_kbps: 8_000, keyframe_interval: 30]
       ]}
    ]
  }

  setup do
    start_supervised!(VisionCore.Outputs)

    start_supervised!(
      {VisionCore.Video, config: @config, videos: [hq: :full_h264], in_flight_frames: 1}
    )

    :ok
  end

  defp join(topic) do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.VideoChannel, topic)
  end

  defp publish(h264, keyframe?) do
    frame = %Frame{
      label: "hq",
      output: :full_h264,
      width: 2028,
      height: 1520,
      capture_ns: -1_234_567_890,
      h264: h264,
      keyframe?: keyframe?
    }

    VisionCore.Outputs.publish(
      {:camera_frame, V4L2Single.name_for("hq"), :full_h264},
      {:camera_frame, frame}
    )
  end

  test "video:<camera> pushes each frame as its flags, capture time and size, then its H.264" do
    {:ok, _reply, socket} = join("video:hq")

    publish(<<0, 0, 0, 1, 0x65>>, true)
    assert_push "frame", {:binary, payload}

    # The socket's serializer takes a binary payload, not iodata.
    assert payload ==
             <<1, -1_234_567::little-signed-64, 2028::little-16, 1520::little-16, 0, 0, 0, 1,
               0x65>>

    push(socket, "ack", %{})
    publish(<<0, 0, 0, 1, 0x41>>, false)
    assert_push "frame", {:binary, payload}
    assert <<0, _rest::binary-12, 0, 0, 0, 1, 0x41>> = payload
  end

  test "the next frame waits for the client's ack once the frames in flight are unacknowledged" do
    {:ok, _reply, socket} = join("video:hq")
    publish("first", true)
    assert_push "frame", {:binary, first}
    assert <<1, _header::binary-12, "first">> = first

    publish("second", false)
    refute_push "frame", {:binary, _second}, 200

    push(socket, "ack", %{})
    assert_push "frame", {:binary, second}, 500
    assert <<0, _header::binary-12, "second">> = second
  end

  test "refuses a camera whose video is not relayed" do
    assert {:error, %{reason: "unknown video"}} = join("video:front")
  end

  test "refuses the join while the relay is not running" do
    stop_supervised!(VisionCore.Video)
    assert {:error, %{reason: "unavailable"}} = join("video:hq")
  end
end
