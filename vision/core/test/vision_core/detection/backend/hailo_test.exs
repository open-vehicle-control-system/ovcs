defmodule VisionCore.Detection.Backend.HailoTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Hailo

  @moduletag :tmp_dir
  @moduletag :capture_log

  @executable Path.expand("../../../support/fake_hailo.py", __DIR__)
  @server {VisionCore.Hailo, :objects}

  defp start_hailo(tmp_dir, mode) do
    hef_path = Path.join(tmp_dir, "model.hef")
    File.write!(hef_path, mode)

    start_supervised!(
      {VisionCore.Hailo,
       networks: [objects: [kind: :detection, hef_path: hef_path]],
       executable: @executable,
       working_directory: tmp_dir,
       library_path: tmp_dir,
       reopen_delays_ms: [20]}
    )
  end

  defp eventually(check, attempts \\ 300) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "detects on its pipeline's lane of VisionCore.Hailo, the process every Hailo unit shares",
       %{tmp_dir: tmp_dir} do
    start_hailo(tmp_dir, "answer")
    assert Hailo.shared_process() == VisionCore.Hailo
    assert Hailo.shared_server(:objects) == @server
    eventually(fn -> Hailo.available?(@server) end)

    assert Hailo.detect(@server, 1, Nx.iota({2, 3, 3}, type: :u8)) == :ok
    assert_receive {:inference_detections, 1, [%{class_id: 2, x1: 3.0, y1: 2.0}]}
    assert Hailo.inference_times(@server) == %{sum_us: 1500, count: 1}
    assert Hailo.state(@server) == :running
  end

  test "answers busy while a frame is in flight", %{tmp_dir: tmp_dir} do
    start_hailo(tmp_dir, "hang")
    eventually(fn -> Hailo.available?(@server) end)

    assert Hailo.detect(@server, 1, Nx.iota({2, 3}, type: :u8)) == :ok
    assert Hailo.detect(@server, 2, Nx.iota({2, 3}, type: :u8)) == {:error, :busy}
  end

  test "is unavailable while VisionCore.Hailo is not running" do
    assert Hailo.detect(@server, 1, Nx.iota({2, 3}, type: :u8)) == {:error, :unavailable}
    refute Hailo.available?(@server)
    assert Hailo.state(@server) == :failed
    assert Hailo.inference_times(@server) == nil
  end

  test "declares its pipeline's inference step: its model and threshold, on the accelerator" do
    group =
      Hailo.inference_group(%{pipeline: :road, hef_path: "/models/m.hef", score_threshold: 0.5})

    assert group.id == "road.inference"
    assert group.compute.runs_on == :npu
    assert Enum.map(group.parameters, & &1.name) == ["model", "score_threshold"]
  end
end
