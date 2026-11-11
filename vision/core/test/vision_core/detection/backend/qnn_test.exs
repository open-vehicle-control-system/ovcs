defmodule VisionCore.Detection.Backend.QnnTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Qnn

  @moduletag :tmp_dir
  @moduletag :capture_log

  @detector Path.expand("../../../support/fake_hailo_detect.py", __DIR__)
  @generator Path.expand("../../../support/fake_qnn_context_binary_generator.sh", __DIR__)
  @image Nx.iota({2, 3}, type: :u8)

  # The DLC's text becomes the context binary's, which picks what the fake Port does.
  defp start_backend(dir, mode, opts \\ []) do
    qairt = Path.join(dir, "qairt")
    File.mkdir_p!(Path.join(qairt, "lib"))
    File.mkdir_p!(Path.join(qairt, "bin"))
    File.write!(Path.join(qairt, "lib/libQnnHtp.so"), "library")
    File.cp!(@generator, Path.join(qairt, "bin/qnn-context-binary-generator"))
    dlc = Path.join(dir, "model.dlc")
    File.write!(dlc, mode)

    start_supervised!(
      {Qnn,
       [
         dlc_path: dlc,
         qairt_dir: qairt,
         cache_dir: Path.join(dir, "cache"),
         executable: @detector,
         reopen_delays_ms: [20]
       ] ++ opts}
    )
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "detections from the Port reach the caller in the submitted image's pixels", %{
    tmp_dir: dir
  } do
    start_backend(dir, "answer")
    eventually(&Qnn.available?/0)

    assert Qnn.detect(7, @image) == :ok
    assert_receive {:inference_detections, 7, [detection]}, 2_000
    assert %{class_id: 0, x0: +0.0, y0: +0.0, x1: 3.0, y1: 2.0} = detection
  end

  test "busy while a request is in flight", %{tmp_dir: dir} do
    start_backend(dir, "hang", infer_timeout_ms: 5_000)
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert Qnn.detect(2, @image) == {:error, :busy}
  end

  test "a named pipeline's backend runs under its server name and declares that pipeline's step",
       %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_backend(dir, "answer", name: Qnn.Road, pipeline: :road)
    eventually(fn -> Qnn.available?(Qnn.Road) end)

    assert Qnn.detect(Qnn.Road, 7, @image) == :ok
    assert_receive {:inference_detections, 7, [_detection]}, 2_000
    refute Process.whereis(Qnn)

    assert %{pipeline: :road, position: 102} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))
  end

  test "log lines name a named pipeline", %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer", name: Qnn.Road, pipeline: :road)
        eventually(fn -> Qnn.available?(Qnn.Road) end)
      end)

    assert log =~ "#{inspect(Qnn)} (road) loaded model.dlc"
  end

  test "log lines of the default pipeline carry no pipeline name", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer")
        eventually(fn -> Qnn.available?() end)
      end)

    assert log =~ "#{inspect(Qnn)} loaded model.dlc"
  end

  # The context cache removes every other binary in its directory, so each pipeline has its own.
  test "keeps the default pipeline's context binary in /data/vision/qnn, a named one's in a directory of its own",
       %{tmp_dir: dir} do
    missing = [dlc_path: Path.join(dir, "missing.dlc"), executable: @detector]

    for {opts, cache_dir} <- [
          {[], "/data/vision/qnn"},
          {[name: Qnn.Road, pipeline: :road], "/data/vision/qnn/road"},
          {[name: Qnn.Road, pipeline: :road, cache_dir: dir], dir}
        ] do
      backend = start_supervised!({Qnn, missing ++ opts})

      assert :sys.get_state(backend).cache_dir == cache_dir
      stop_supervised!(Qnn)
    end
  end

  test "a missing DLC or QAIRT leaves the backend unavailable", %{tmp_dir: dir} do
    backend =
      start_supervised!(
        {Qnn,
         dlc_path: Path.join(dir, "missing.dlc"),
         qairt_dir: Path.join(dir, "no-qairt"),
         cache_dir: dir,
         executable: @detector}
      )

    refute Qnn.available?()
    assert Qnn.detect(1, @image) == {:error, :unavailable}
    assert Process.alive?(backend)
  end
end
