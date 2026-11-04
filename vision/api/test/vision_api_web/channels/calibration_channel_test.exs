defmodule VisionApiWeb.CalibrationChannelTest do
  use VisionApiWeb.CalibrationCase
  import Phoenix.ChannelTest

  alias VisionCore.Calibration.{Board, Session}

  defp join do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.CalibrationChannel, "calibration")
  end

  test "join pushes the session and the calibration in use" do
    {:ok, _reply, _socket} = join()

    assert_push "session", %{phase: "idle", board: nil, samples: 0, goodEnough: false}
    assert_push "in_use", %{source: "builtIn", prefix: "unit", left: %{fx: 900.0}}
  end

  test "a session change is pushed" do
    {:ok, _reply, _socket} = join()
    assert_push "session", %{phase: "idle"}

    {:ok, board} = Board.new(8, 6, 0.025)
    :ok = Session.start(board)

    assert_push "session", %{phase: "capturing", board: %{columns: 8, rows: 6, squareMm: 25.0}}
  end

  test "a change of the calibration in use is pushed" do
    {:ok, _reply, _socket} = join()
    assert_push "in_use", %{}

    VisionCore.Outputs.publish(
      VisionCore.Stereo.Calibration.changed_key("unit"),
      {:stereo_calibration_changed, "unit"}
    )

    assert_push "in_use", %{source: "builtIn"}
  end

  test "the channel stops when the session restarts" do
    Process.flag(:trap_exit, true)
    {:ok, _reply, socket} = join()
    monitor = Process.monitor(socket.channel_pid)

    Process.exit(Process.whereis(Session), :kill)

    assert_receive {:DOWN, ^monitor, :process, _pid, :source_restarted}, 500
  end

  test "leaving the channel unsubscribes from the session" do
    {:ok, _reply, socket} = join()
    assert_push "session", %{}
    assert map_size(:sys.get_state(Session).subscribers) == 1

    Process.flag(:trap_exit, true)
    close(socket)

    assert wait_until(fn -> :sys.get_state(Session).subscribers == %{} end)
  end

  test "joining a unit without a :stereo component is refused without a retry reason" do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    assert {:error, %{reason: "no stereo unit"}} = join()
  end

  defp wait_until(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && wait_until(check, attempts - 1)
    end
  end

  test "joining while the session is down is refused as unavailable" do
    stop_supervised!(Session)

    assert {:error, %{reason: "unavailable"}} = join()
  end
end
