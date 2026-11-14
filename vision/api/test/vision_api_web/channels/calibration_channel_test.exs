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

    assert_push "calibration", %{id: "unit", kind: "stereo", source: "builtIn", cameras: [_, _]}
    assert_push "calibration", %{id: "hq", kind: "camera", cameras: [%{name: "hq", fx: 900.0}]}

    assert_push "session", %{
      phase: "idle",
      calibration: nil,
      board: nil,
      samples: 0,
      goodEnough: false
    }
  end

  @tag :capture_log
  test "join pushes a calibration whose file cannot be read, with why", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "hq.yaml"), "camera_matrix:\n  data: [1, 2]\n")

    {:ok, _reply, _socket} = join()

    assert_push "calibration", %{id: "hq", error: error, cameras: [%{name: "hq", fx: nil}]}
    assert error =~ "camera matrix"
  end

  test "a session change is pushed" do
    {:ok, _reply, _socket} = join()
    assert_push "session", %{phase: "idle"}

    {:ok, board} = Board.new(8, 6, 0.025)
    :ok = Session.start("hq", board)

    assert_push "session", %{
      phase: "capturing",
      calibration: "hq",
      board: %{columns: 8, rows: 6, squareMm: 25.0}
    }
  end

  test "a change of a calibration in use is pushed, the pair's or a camera's" do
    {:ok, _reply, _socket} = join()
    assert_push "calibration", %{id: "unit"}
    assert_push "calibration", %{id: "hq"}

    VisionCore.Outputs.publish(
      VisionCore.Stereo.Calibration.changed_key("unit"),
      {:stereo_calibration_changed, "unit"}
    )

    assert_push "calibration", %{id: "unit", source: "builtIn"}

    VisionCore.Outputs.publish(
      VisionCore.Camera.Calibration.changed_key(:hq),
      {:camera_calibration_changed, :hq}
    )

    assert_push "calibration", %{id: "hq", source: "builtIn"}
  end

  test "a change of the calibrations kept for a target is pushed with its calibration's id" do
    {:ok, _reply, _socket} = join()
    assert_push "session", %{phase: "idle"}

    VisionCore.Calibration.Recorder.changed("hq")
    assert_push "saved", %{calibration: "hq"}
  end

  test "the channel takes no push: it refuses one, changes nothing and stays" do
    {:ok, _reply, socket} = join()

    reference = Phoenix.ChannelTest.push(socket, "session", %{"phase" => "capturing"})

    assert_reply reference, :error, %{reason: "unknown event"}
    assert Process.alive?(socket.channel_pid)
    assert %{phase: :idle} = Session.state()
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

  test "joining a unit with nothing to calibrate is refused without a retry reason" do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    assert {:error, %{reason: "nothing to calibrate"}} = join()
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
