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

  test "preview:left pushes each frame as its JPEG bytes" do
    {:ok, _reply, _socket} = join("preview:left")
    jpeg = <<0xFF, 0xD8, 1, 2, 3>>

    feed_left(jpeg)

    assert_push "frame", {:binary, ^jpeg}
  end

  test "the next frame waits for the client's ack" do
    {:ok, _reply, socket} = join("preview:left")
    feed_left("first")
    assert_push "frame", {:binary, "first"}

    feed_left("second")
    refute_push "frame", {:binary, _second}, 200

    push(socket, "ack", %{})
    assert_push "frame", {:binary, "second"}, 500
  end

  test "the depth stream sets the depth video's colour range and answers the one in force" do
    {:ok, _reply, socket} = join("preview:depth")

    ref = push(socket, "depth_range", %{})
    assert_reply ref, :ok, %{metres: +0.0}

    ref = push(socket, "depth_range", %{"metres" => 8.5})
    assert_reply ref, :ok, %{metres: 8.5}
    assert VisionCore.Preview.options().depth_range_m == 8.5

    ref = push(socket, "depth_range", %{"metres" => -1})
    assert_reply ref, :error, %{reason: "depth_range_m" <> _}
    assert VisionCore.Preview.options().depth_range_m == 8.5
  end

  test "the depth stream pushes a colour range set from anywhere" do
    {:ok, _reply, _socket} = join("preview:depth")

    {:ok, _options} = VisionCore.Preview.set_options(depth_range_m: 9.0)

    assert_push "depth_range", %{metres: 9.0}
  end

  test "a camera stream has no colour range" do
    {:ok, _reply, socket} = join("preview:left")

    ref = push(socket, "depth_range", %{"metres" => 8.5})
    assert_reply ref, :error, %{reason: "only the depth stream has a colour range"}
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
