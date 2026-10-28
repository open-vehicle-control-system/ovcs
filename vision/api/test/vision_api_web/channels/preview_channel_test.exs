defmodule VisionApiWeb.PreviewChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.Frame

  setup do
    config = %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}
    start_supervised!({VisionCore.Preview, config: config, max_hz: 50})
    :ok
  end

  defp join(topic) do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.PreviewChannel, topic)
  end

  defp feed_left(jpeg) do
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 0, jpeg: jpeg}
    GenServer.cast(VisionCore.Preview, {:camera_frame, frame})
  end

  test "preview:left pushes frame with base64 jpeg" do
    {:ok, _reply, _socket} = join("preview:left")
    jpeg = <<0xFF, 0xD8, 1, 2, 3>>

    feed_left(jpeg)

    assert_push "frame", %{jpeg: encoded}
    assert Base.decode64!(encoded) == jpeg
  end

  test "the next frame waits for the client's ack" do
    {:ok, _reply, socket} = join("preview:left")
    feed_left("first")
    assert_push "frame", %{jpeg: _first}

    feed_left("second")
    refute_push "frame", %{jpeg: _second}, 200

    push(socket, "ack", %{})
    assert_push "frame", %{jpeg: second}, 500
    assert Base.decode64!(second) == "second"
  end

  test "the channel stops when the preview server restarts" do
    Process.flag(:trap_exit, true)
    {:ok, _reply, socket} = join("preview:left")
    monitor = Process.monitor(socket.channel_pid)

    Process.exit(Process.whereis(VisionCore.Preview), :kill)

    assert_receive {:DOWN, ^monitor, :process, _pid, :source_restarted}, 500
  end

  test "joining while the preview server is down is refused as unavailable" do
    stop_supervised!(VisionCore.Preview)

    assert {:error, %{reason: "unavailable"}} = join("preview:left")
  end

  test "joining preview:foo is refused" do
    assert {:error, %{reason: "unknown stream"}} = join("preview:foo")
  end
end
