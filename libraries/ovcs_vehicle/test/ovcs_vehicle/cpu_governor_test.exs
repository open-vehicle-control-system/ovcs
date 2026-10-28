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

  test "is a no-op when no governor file exists", %{tmp_dir: dir} do
    assert :ok = CpuGovernor.apply_governor(glob: Path.join(dir, "cpu*/scaling_governor"))
  end
end
