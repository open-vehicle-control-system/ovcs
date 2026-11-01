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
    eventually(fn -> starts(hef_path) == 2 and Hailo.available?() end)
    assert Hailo.detect(2, @image) == :ok
  end

  test "stays unavailable without its model", %{tmp_dir: tmp_dir} do
    start_supervised!(
      {Hailo, hef_path: Path.join(tmp_dir, "missing.hef"), executable: @executable}
    )

    assert Hailo.detect(1, @image) == {:error, :unavailable}
    refute Hailo.available?()
  end
end
