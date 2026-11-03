defmodule OvcsVehicle.CpuGovernorTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.CpuGovernor

  @moduletag :tmp_dir

  test "writes performance to every matching governor file", %{tmp_dir: dir} do
    paths =
      for cpu <- ["cpu0", "cpu1"] do
        path = Path.join([dir, cpu, "scaling_governor"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "schedutil")
        path
      end

    assert :ok = CpuGovernor.apply_governor(glob: Path.join(dir, "cpu*/scaling_governor"))
    assert Enum.map(paths, &File.read!/1) == ["performance", "performance"]
  end

  test "names the devices it set in its log line, CPUs by default", %{tmp_dir: dir} do
    path = Path.join([dir, "gpu", "governor"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "simple_ondemand")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        CpuGovernor.apply_governor(glob: path, devices: "GPU")
      end)

    assert log =~ "1 GPU(s) set to performance"
    assert File.read!(path) == "performance"

    assert ExUnit.CaptureLog.capture_log(fn ->
             CpuGovernor.apply_governor(glob: Path.join(dir, "cpu*/scaling_governor"))
           end) =~ "0 CPU(s) set to performance"
  end

  test "is a no-op when no governor file exists", %{tmp_dir: dir} do
    assert :ok = CpuGovernor.apply_governor(glob: Path.join(dir, "cpu*/scaling_governor"))
  end
end
