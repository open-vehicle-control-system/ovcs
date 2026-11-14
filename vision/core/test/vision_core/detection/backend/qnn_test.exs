defmodule VisionCore.Detection.Backend.QnnTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Backend.Qnn

  @moduletag :tmp_dir
  @moduletag :capture_log

  @detector Path.expand("../../../support/fake_hailo_detect.py", __DIR__)
  @generator Path.expand("../../../support/fake_qnn_context_binary_generator.sh", __DIR__)
  @image Nx.iota({2, 3}, type: :u8)

  # The DLC's text becomes the context binary's, which picks what the fake Port does.
  defp start_backend_files(dir) do
    qairt = Path.join(dir, "qairt")
    File.mkdir_p!(Path.join(qairt, "lib"))
    File.mkdir_p!(Path.join(qairt, "bin"))
    File.write!(Path.join(qairt, "lib/libQnnHtp.so"), "library")
    File.cp!(@generator, Path.join(qairt, "bin/qnn-context-binary-generator"))
    qairt
  end

  defp start_backend(dir, mode, opts \\ []) do
    qairt = start_backend_files(dir)
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

  # The fake Port's class id is the channel count it was sent, less one.
  test "sends an RGB frame's three channels", %{tmp_dir: dir} do
    start_backend(dir, "answer")
    eventually(&Qnn.available?/0)

    assert Qnn.detect(7, Nx.iota({2, 3, 3}, type: :u8)) == :ok
    assert_receive {:inference_detections, 7, [detection]}, 2_000
    assert %{class_id: 2, x1: 3.0, y1: 2.0} = detection
  end

  test "sums the inference times the replies carry and starts over once they are read", %{
    tmp_dir: dir
  } do
    start_backend(dir, "answer")
    eventually(&Qnn.available?/0)

    for sequence <- [1, 2] do
      assert Qnn.detect(sequence, @image) == :ok
      assert_receive {:inference_detections, ^sequence, _detections}, 2_000
    end

    assert Qnn.inference_times() == %{sum_us: 3_000, count: 2}
    assert Qnn.inference_times() == %{sum_us: 0, count: 0}
  end

  test "reports no inference times while the replies carry none", %{tmp_dir: dir} do
    start_backend(dir, "answer_untimed")
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, [_detection]}, 2_000
    assert Qnn.inference_times() == nil
  end

  test "reports no inference times once the Port went down", %{tmp_dir: dir} do
    start_backend(dir, "answer_once", reopen_delays_ms: [60_000])
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, _detections}, 2_000
    eventually(fn -> not Qnn.available?() end)
    assert Qnn.inference_times() == nil
  end

  test "reports no inference times without a Port" do
    start_supervised!({Qnn, dlc_path: "/missing.dlc", executable: "/missing"})

    assert Qnn.inference_times() == nil
  end

  test "busy while a request is in flight", %{tmp_dir: dir} do
    start_backend(dir, "hang", infer_timeout_ms: 5_000)
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert Qnn.detect(2, @image) == {:error, :busy}
  end

  test "a frame left unanswered is no detections, and the Port restarted", %{tmp_dir: dir} do
    start_backend(dir, "hang", infer_timeout_ms: 200)
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, nil}, 1_000
    eventually(fn -> Qnn.detect(2, @image) == :ok end)
  end

  test "a frame in flight when the Port exits is no detections", %{tmp_dir: dir} do
    start_backend(dir, "die", reopen_delays_ms: [60_000])
    eventually(&Qnn.available?/0)

    assert Qnn.detect(1, @image) == :ok
    assert_receive {:inference_detections, 1, nil}, 2_000
  end

  test "answers at once, unavailable, while its context binary is generated, then opens the Port",
       %{tmp_dir: dir} do
    hold = Path.join(dir, "qairt/bin/hold")
    File.mkdir_p!(Path.dirname(hold))
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    start_backend(dir, "answer")

    submitted = Task.async(fn -> Qnn.detect(1, @image) end)
    assert Task.yield(submitted, 500) == {:ok, {:error, :unavailable}}
    refute Qnn.available?()
    assert Qnn.state() == :starting

    File.rm!(hold)
    eventually(&Qnn.available?/0)
    assert Qnn.state() == :running
    assert Qnn.detect(2, @image) == :ok
    assert_receive {:inference_detections, 2, [_detection]}, 2_000
  end

  test "opens the Port once its context binary is generated, after a generation that failed",
       %{tmp_dir: dir} do
    fail = Path.join(dir, "qairt/bin/fail")
    File.mkdir_p!(Path.dirname(fail))
    File.write!(fail, "")
    start_backend(dir, "answer")
    eventually(fn -> File.exists?(Path.join(dir, "qairt/bin/failed")) end)
    refute Qnn.available?()

    File.rm!(fail)

    eventually(&Qnn.available?/0)
    assert Qnn.detect(1, @image) == :ok
  end

  test "does not try again without its DLC", %{tmp_dir: dir} do
    dlc = Path.join(dir, "late.dlc")

    start_supervised!(
      {Qnn,
       dlc_path: dlc,
       qairt_dir: Path.join(dir, "qairt"),
       cache_dir: Path.join(dir, "cache"),
       executable: @detector,
       reopen_delays_ms: [0]}
    )

    eventually(fn -> is_nil(:sys.get_state(Qnn).opening) end)
    start_backend_files(dir)
    File.write!(dlc, "answer")
    Process.sleep(200)

    refute Qnn.available?()
    assert Qnn.state() == :failed
    assert is_nil(:sys.get_state(Qnn).opening)
  end

  test "a context binary that cannot be generated leaves the backend unavailable, saying why",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, "cache"), "a file where the cache directory goes")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer")
        eventually(fn -> is_nil(:sys.get_state(Qnn).opening) end)
        refute Qnn.available?()
      end)

    assert log =~ "#{inspect(Qnn)} (detection) unavailable"
    assert Qnn.detect(1, @image) == {:error, :unavailable}
  end

  test "takes the board's QAIRT, DSP libraries and Hexagon architecture, the VENTUNO Q's by default" do
    assert VisionCore.Inference.QnnPort.runtime([]) == [
             qairt_dir: "/opt/qairt",
             dsp_library_path: "/usr/share/qcom/qcs8300/Arduino/Monza/dsp/cdsp",
             dsp_architecture: "hexagon-v75"
           ]

    assert VisionCore.Inference.QnnPort.runtime(
             qairt_dir: "/qairt",
             dsp_library_path: "/dsp",
             dsp_architecture: "hexagon-v79",
             dlc_path: "/model.dlc"
           ) == [qairt_dir: "/qairt", dsp_library_path: "/dsp", dsp_architecture: "hexagon-v79"]
  end

  test "hands the Port its performance profile and RPC polling when given", %{tmp_dir: dir} do
    for {opts, arguments} <- [
          {[], "0.4"},
          {[performance: :balanced], "0.4 --performance balanced"},
          {[performance: :none], "0.4 --performance none"},
          {[rpc_polling_us: 0], "0.4 --rpc-polling-us 0"},
          {[performance: :balanced, rpc_polling_us: 9999],
           "0.4 --performance balanced --rpc-polling-us 9999"}
        ] do
      start_backend(dir, "answer", opts)
      eventually(&Qnn.available?/0)
      assert Qnn.detect(1, @image) == :ok
      assert_receive {:inference_detections, 1, _detections}, 2_000

      assert [file] = dir |> Path.join("cache/*.bin.arguments") |> Path.wildcard()
      assert File.read!(file) == arguments
      stop_supervised!(Qnn)
      File.rm!(file)
    end
  end

  test "refuses at start an :infer_timeout_ms, :reopen_delays_ms, :performance or :rpc_polling_us it cannot use",
       %{tmp_dir: dir} do
    profiles = "one of [:burst, :sustained_high_performance, :balanced, :power_saver, :none]"
    polling = "an integer from 0 to 9999"

    for {key, value, expected} <- [
          {:performance, :turbo, profiles},
          {:performance, "burst", profiles},
          {:rpc_polling_us, -1, polling},
          {:rpc_polling_us, 10_000, polling},
          {:rpc_polling_us, 1.5, polling},
          {:rpc_polling_us, "0", polling},
          {:infer_timeout_ms, 0, "a positive integer"},
          {:infer_timeout_ms, 1.5, "a positive integer"},
          {:reopen_delays_ms, [], "a non-empty list of non-negative integers"},
          {:reopen_delays_ms, [1_000, -1], "a non-empty list of non-negative integers"},
          {:reopen_delays_ms, 1_000, "a non-empty list of non-negative integers"}
        ] do
      assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
               start_supervised(
                 {Qnn,
                  [{key, value} | [dlc_path: Path.join(dir, "model.dlc"), executable: @detector]]}
               )

      assert message == "its #{inspect(key)} is #{expected}, got #{inspect(value)}"
    end
  end

  test "refuses at start an :rpc_polling_us without a power vote", %{tmp_dir: dir} do
    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised(
               {Qnn,
                [
                  performance: :none,
                  rpc_polling_us: 0,
                  dlc_path: Path.join(dir, "model.dlc"),
                  executable: @detector
                ]}
             )

    assert message ==
             "its :rpc_polling_us is part of the power vote, which performance: :none does not make"
  end

  test "a named pipeline's backend runs under its server name and declares that pipeline's step",
       %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_backend(dir, "answer", name: VisionCore.Pipelines.server(Qnn, :road), pipeline: :road)
    eventually(fn -> Qnn.available?(VisionCore.Pipelines.server(Qnn, :road)) end)

    assert Qnn.detect(VisionCore.Pipelines.server(Qnn, :road), 7, @image) == :ok
    assert_receive {:inference_detections, 7, [_detection]}, 2_000
    refute Process.whereis(Qnn)

    assert %{pipeline: :road, position: 102} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))
  end

  test "lists what is fixed at start: its model, threshold, power vote and timeout", %{
    tmp_dir: dir
  } do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})
    start_backend(dir, "answer", score_threshold: 1, performance: :balanced)

    group = Enum.find(VisionCore.Parameters.groups(), &(&1.id == "detection.inference"))

    assert Enum.map(group.parameters, &{&1.name, &1.type, &1.value, &1.applies}) == [
             {"model", :string, "model.dlc", :build},
             {"score_threshold", :double, 1.0, :build},
             {"performance", :string, "balanced", :build},
             {"rpc_polling_us", :integer, 0, :build},
             {"infer_timeout_ms", :integer, 2000, :build}
           ]
  end

  test "log lines name a named pipeline", %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer",
          name: VisionCore.Pipelines.server(Qnn, :road),
          pipeline: :road
        )

        eventually(fn -> Qnn.available?(VisionCore.Pipelines.server(Qnn, :road)) end)
      end)

    assert log =~ "#{inspect(Qnn)} (road) loaded model.dlc"
  end

  test "log lines name the pipeline, detection without one", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer")
        eventually(fn -> Qnn.available?() end)
      end)

    assert log =~ "#{inspect(Qnn)} (detection) loaded model.dlc"
  end

  # The context cache removes every other binary in its directory, so each pipeline has its own.
  test "keeps each pipeline's context binary in a directory of its own",
       %{tmp_dir: dir} do
    missing = [dlc_path: Path.join(dir, "missing.dlc"), executable: @detector]

    for {opts, cache_dir} <- [
          {[], "/data/vision/qnn/detection"},
          {[name: VisionCore.Pipelines.server(Qnn, :road), pipeline: :road],
           "/data/vision/qnn/road"},
          {[name: VisionCore.Pipelines.server(Qnn, :road), pipeline: :road, cache_dir: dir], dir}
        ] do
      backend = start_supervised!({Qnn, missing ++ opts})

      assert :sys.get_state(backend).settings.cache_dir == cache_dir
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
