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

  test "pins a devfreq device at its maximum frequency when it has no performance governor",
       %{tmp_dir: dir} do
    gpu = Path.join(dir, "gpu")
    File.mkdir_p!(gpu)

    for {file, value} <- [
          governor: "simple_ondemand",
          min_freq: "479000000",
          max_freq: "877000000"
        ],
        do: File.write!(Path.join(gpu, "#{file}"), value)

    # A governor the device does not offer is refused, as a read-only file refuses the write.
    File.chmod!(Path.join(gpu, "governor"), 0o444)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        CpuGovernor.apply_governor(glob: Path.join(gpu, "governor"), devices: "GPU")
      end)

    assert File.read!(Path.join(gpu, "min_freq")) == "877000000"
    assert log =~ "1 GPU(s) pinned at their maximum frequency"
  end

  test "waits up to :await milliseconds for a device that is not there yet", %{tmp_dir: dir} do
    path = Path.join([dir, "gpu", "governor"])

    spawn_link(fn ->
      Process.sleep(200)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path <> ".new", "simple_ondemand")
      File.rename!(path <> ".new", path)
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      CpuGovernor.apply_governor(glob: path, devices: "GPU", await: 2_000)
    end)

    assert File.read!(path) == "performance"
  end

  test "is a no-op when no governor file exists", %{tmp_dir: dir} do
    assert :ok = CpuGovernor.apply_governor(glob: Path.join(dir, "cpu*/scaling_governor"))
  end
end
