defmodule VisionApiWeb.StatusChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  setup do
    config = %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: []}
    start_supervised!({VisionCore.Status, config: config})
    :ok
  end

  defp join do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.StatusChannel, "status")
  end

  test "status channel pushes a snapshot on join" do
    {:ok, _reply, _socket} = join()

    assert_push "status", %{zenoh: :disconnected, hailo: :absent, depth_hz: +0.0}
  end

  test "the channel stops when the status server restarts" do
    Process.flag(:trap_exit, true)
    {:ok, _reply, socket} = join()
    monitor = Process.monitor(socket.channel_pid)

    Process.exit(Process.whereis(VisionCore.Status), :kill)

    assert_receive {:DOWN, ^monitor, :process, _pid, :source_restarted}, 500
  end

  test "joining while the status server is down is refused as unavailable" do
    stop_supervised!(VisionCore.Status)

    assert {:error, %{reason: "unavailable"}} = join()
  end
end
