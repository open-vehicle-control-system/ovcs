defmodule VisionCore.Detection.Backend.HailoTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Hailo

  @moduletag :tmp_dir
  @moduletag :capture_log

  @executable Path.expand("../../../support/fake_hailo_detect.py", __DIR__)
  @image Nx.iota({2, 3}, type: :u8)

  defp start_backend(tmp_dir, mode, opts \\ []) do
    hef_path = Path.join(tmp_dir, "model.hef")
    File.write!(hef_path, mode)

    start_supervised!(
      {Hailo,
       [
         hef_path: hef_path,
         executable: @executable,
         working_directory: tmp_dir,
         library_path: tmp_dir,
         reopen_delays_ms: [20]
       ] ++ opts}
    )

    hef_path
  end

  defp starts(hef_path) do
    case File.read(hef_path <> ".starts") do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "sends a frame and delivers its detections in the submitted image's pixels", %{
    tmp_dir: tmp_dir
  } do
    start_backend(tmp_dir, "answer")

    assert Hailo.detect(7, @image) == :ok
    assert_receive {:inference_detections, 7, [detection]}, 2_000
    assert %{class_id: 0, x0: +0.0, y0: +0.0, x1: 3.0, y1: 2.0} = detection
    assert_in_delta detection.score, 0.9, 1.0e-6
  end

  # The fake Port's class id is the channel count it was sent, less one.
  test "sends an RGB frame's three channels", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "answer")

    assert Hailo.detect(7, Nx.iota({2, 3, 3}, type: :u8)) == :ok
    assert_receive {:inference_detections, 7, [detection]}, 2_000
    assert %{class_id: 2, x1: 3.0, y1: 2.0} = detection
  end

  test "sums the inference times the replies carry and starts over once they are read", %{
    tmp_dir: tmp_dir
  } do
    start_backend(tmp_dir, "answer")

    for sequence <- [1, 2] do
      assert Hailo.detect(sequence, @image) == :ok
      assert_receive {:inference_detections, ^sequence, _detections}, 2_000
    end

    assert Hailo.inference_times() == %{sum_us: 3_000, count: 2}
    assert Hailo.inference_times() == %{sum_us: 0, count: 0}
  end

  test "reports no inference times while the replies carry none", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "answer_untimed")

    assert Hailo.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, [_detection]}, 2_000
    assert Hailo.inference_times() == nil
  end

  test "reports no inference times once the Port went down", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "answer_once", reopen_delays_ms: [60_000])

    assert Hailo.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, _detections}, 2_000
    eventually(fn -> not Hailo.available?() end)
    assert Hailo.inference_times() == nil
  end

  test "reports no inference times while the Port is down", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "exit", reopen_delays_ms: [60_000])

    assert Hailo.inference_times() == nil
  end

  test "hands hailo_detect's log lines to the Logger", %{tmp_dir: tmp_dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(tmp_dir, "answer")
        assert Hailo.detect(1, @image) == :ok
        assert_receive {:inference_detections, 1, _detections}, 2_000
      end)

    assert log =~ "hailo_detect: ready"
  end

  test "answers busy while a frame is in flight", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "hang", infer_timeout_ms: 5_000)

    assert Hailo.detect(1, @image) == :ok
    assert Hailo.detect(2, @image) == {:error, :busy}
  end

  test "reopens hailo_detect after it exits, in the same process", %{tmp_dir: tmp_dir} do
    hef_path = start_backend(tmp_dir, "exit")
    backend = Process.whereis(Hailo)

    eventually(fn -> starts(hef_path) >= 3 end)
    assert Process.whereis(Hailo) == backend
  end

  test "closes hailo_detect when a frame is not answered in time, and reopens it", %{
    tmp_dir: tmp_dir
  } do
    hef_path = start_backend(tmp_dir, "hang", infer_timeout_ms: 50)

    assert Hailo.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, nil}, 1_000
    eventually(fn -> starts(hef_path) == 2 and Hailo.available?() end)
    assert Hailo.detect(2, @image) == :ok
  end

  test "a frame in flight when hailo_detect exits is no detections", %{tmp_dir: tmp_dir} do
    start_backend(tmp_dir, "die", reopen_delays_ms: [60_000])
    eventually(&Hailo.available?/0)

    assert Hailo.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, nil}, 2_000
  end

  test "declares the inference step: its model and threshold, on the accelerator", %{
    tmp_dir: tmp_dir
  } do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_backend(tmp_dir, "answer", score_threshold: 0.3)

    assert %{
             pipeline: :detection,
             position: 102,
             compute: %{runs_on: :npu, implementation: :rust},
             parameters: [model, threshold]
           } = Enum.find(VisionCore.Parameters.groups(), &(&1.id == "detection.inference"))

    assert {model.name, model.value, model.applies} == {"model", "model.hef", :build}
    assert {threshold.name, threshold.value} == {"score_threshold", 0.3}
  end

  test "a named pipeline's backend runs under its server name and declares that pipeline's step",
       %{tmp_dir: tmp_dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_backend(tmp_dir, "answer", name: Hailo.Road, pipeline: :road)

    assert Hailo.detect(Hailo.Road, 7, @image) == :ok
    assert_receive {:inference_detections, 7, [_detection]}, 2_000
    assert Hailo.available?(Hailo.Road)
    refute Process.whereis(Hailo)

    assert %{pipeline: :road, position: 102} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))
  end

  test "log lines name a named pipeline, the default's do not", %{tmp_dir: tmp_dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(tmp_dir, "answer", name: Hailo.Road, pipeline: :road)
        eventually(fn -> Hailo.available?(Hailo.Road) end)
      end)

    assert log =~ "#{inspect(Hailo)} (road) loaded model.hef"
  end

  test "opens hailo_detect once it can be started, after a start that failed", %{
    tmp_dir: tmp_dir
  } do
    executable = Path.join(tmp_dir, "hailo_detect")
    File.cp!(@executable, executable)
    File.chmod!(executable, 0o644)
    hef_path = Path.join(tmp_dir, "model.hef")
    File.write!(hef_path, "answer")

    start_supervised!(
      {Hailo,
       hef_path: hef_path,
       executable: executable,
       working_directory: tmp_dir,
       library_path: tmp_dir,
       reopen_delays_ms: [20]}
    )

    assert Hailo.state() == :failed

    File.chmod!(executable, 0o755)

    eventually(fn -> Hailo.state() == :running end)
    assert Hailo.detect(1, @image) == :ok
  end

  test "stays unavailable without its model", %{tmp_dir: tmp_dir} do
    start_supervised!(
      {Hailo, hef_path: Path.join(tmp_dir, "missing.hef"), executable: @executable}
    )

    assert Hailo.detect(1, @image) == {:error, :unavailable}
    refute Hailo.available?()
  end
end
