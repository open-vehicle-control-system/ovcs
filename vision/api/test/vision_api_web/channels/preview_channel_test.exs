defmodule VisionApiWeb.PreviewChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.Frame

  setup do
    config = %VisionCore.Config{}
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

  @tag :capture_log
  test "an event the channel does not take is refused, and the channel stays" do
    {:ok, _reply, socket} = join("preview:left")

    reference = push(socket, "nope", %{})

    assert_reply reference, :error, %{reason: "unknown event"}
    assert Process.alive?(socket.channel_pid)
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

  test "the depth stream pushes the colour range in force after every join" do
    {:ok, _options} = VisionCore.Preview.set_options(depth_range_m: 6.0)

    {:ok, _reply, _socket} = join("preview:depth")
    assert_push "depth_range", %{metres: 6.0}

    {:ok, _reply, _socket} = join("preview:depth")
    assert_push "depth_range", %{metres: 6.0}
  end

  test "a camera stream pushes no colour range on joining" do
    {:ok, _reply, _socket} = join("preview:left")

    refute_push "depth_range", _range
  end

  test "the depth stream pushes a colour range set from anywhere" do
    {:ok, _reply, _socket} = join("preview:depth")

    {:ok, _options} = VisionCore.Preview.set_options(depth_range_m: 9.0)

    assert_push "depth_range", %{metres: 9.0}
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

defmodule VisionApiWeb.PreviewChannelCameraTest do
  use VisionApiWeb.ChannelCase, async: false

  alias VisionCore.Camera.Frame

  # A camera driver that captures nothing.
  defmodule Driver do
    def name_for(label), do: Module.concat(__MODULE__, label)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def start_link(_opts), do: {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
  end

  setup do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{
      components: [{:camera, name: :hq, driver: Driver}],
      preview: [max_hz: 50]
    })
  end

  defp join(topic) do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.PreviewChannel, topic)
  end

  test "preview:<name> pushes the frames of the unit's camera of that name" do
    {:ok, _reply, _socket} = join("preview:hq")
    frame = %Frame{label: "hq", width: 2, height: 2, capture_ns: 0, jpeg: <<0xFF, 0xD8, 7>>}

    VisionCore.Outputs.publish({:camera_frame, Driver.name_for("hq")}, {:camera_frame, frame})

    assert_push "frame", {:binary, <<0xFF, 0xD8, 7>>}
  end

  test "a name the unit has no camera for is refused, and creates no atom" do
    assert {:error, %{reason: "unknown stream"}} = join("preview:nonexistent_camera_xyz")

    assert_raise ArgumentError, fn -> String.to_existing_atom("nonexistent_camera_xyz") end
  end
end
