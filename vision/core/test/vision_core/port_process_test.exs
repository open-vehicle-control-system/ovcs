defmodule VisionCore.PortProcessTest do
  use ExUnit.Case, async: true

  alias VisionCore.PortProcess

  @moduletag :tmp_dir

  defp open(tmp_dir, script) do
    path = Path.join(tmp_dir, "program.sh")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
    Port.open({:spawn_executable, path}, [:binary, :exit_status])
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "kills a program that ignores the end of its stdin", %{tmp_dir: tmp_dir} do
    port = open(tmp_dir, "echo ready\nexec sleep 600 < /dev/null\n")
    assert_receive {^port, {:data, "ready\n"}}, 2_000
    os_pid = PortProcess.os_pid(port)
    assert PortProcess.alive?(os_pid)

    assert PortProcess.close(port, 20) == :ok

    assert Port.info(port) == nil
    eventually(fn -> not PortProcess.alive?(os_pid) end)
  end

  test "leaves alone a program that exits when its stdin ends", %{tmp_dir: tmp_dir} do
    port = open(tmp_dir, "echo ready\ncat > /dev/null\n")
    assert_receive {^port, {:data, "ready\n"}}, 2_000
    os_pid = PortProcess.os_pid(port)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert PortProcess.close(port, 300) == :ok
        eventually(fn -> not PortProcess.alive?(os_pid) end)
        assert PortProcess.kill(os_pid) == :ok
      end)

    refute log =~ "outlived"
  end

  test "a Port already closed is left alone", %{tmp_dir: tmp_dir} do
    port = open(tmp_dir, "exit 0\n")
    assert_receive {^port, {:exit_status, 0}}, 2_000

    assert PortProcess.os_pid(port) == nil
    assert PortProcess.close(port) == :ok
  end
end
