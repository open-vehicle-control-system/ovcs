defmodule VisionApiWeb.StatusChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  setup do
    config = %VisionCore.Config{}
    start_supervised!({VisionCore.Status, config: config})
    :ok
  end

  defp join do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.StatusChannel, "status")
  end

  @tag :capture_log
  test "an event the channel does not take is refused, and the channel stays" do
    {:ok, _reply, socket} = join()

    reference = push(socket, "nope", %{})

    assert_reply reference, :error, %{reason: "unknown event"}
    assert Process.alive?(socket.channel_pid)
  end

  test "status channel pushes a snapshot on join" do
    {:ok, _reply, _socket} = join()

    assert_push "status", %{exporters: [%{id: "api"}], npu: nil, depthHz: +0.0}
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
