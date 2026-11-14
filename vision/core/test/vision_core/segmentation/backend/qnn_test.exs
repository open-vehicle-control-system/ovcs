defmodule VisionCore.Segmentation.Backend.QnnTest do
  use ExUnit.Case, async: false

  alias VisionCore.Segmentation.Backend.Qnn

  @moduletag :tmp_dir
  @moduletag :capture_log

  @segmenter Path.expand("../../../support/fake_qnn_segment.py", __DIR__)
  @generator Path.expand("../../../support/fake_qnn_context_binary_generator.sh", __DIR__)
  # Three rows of five pixels, its first byte 1 and its last 45.
  @band %{width: 5, height: 3, rgb: :binary.list_to_bin(Enum.to_list(1..45))}

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
         executable: @segmenter,
         pipeline: :road,
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

  test "sends the band's rows as an RGB image whose band is all of it, and hands on the label image",
       %{tmp_dir: dir} do
    start_backend(dir, "answer")
    eventually(&Qnn.available?/0)

    assert Qnn.segment(7, @band) == :ok
    assert_receive {:inference_labels, 7, labels}, 2_000

    # band_top, band_height, height, width, first and last pixel bytes, channels, pixels.
    assert labels == %{width: 4, height: 2, data: <<0, 3, 3, 5, 1, 45, 3, 15>>}
  end

  test "hands the Port the number of classes its pipeline names, the 19 Cityscapes ones by default, and its performance profile and RPC polling when given",
       %{tmp_dir: dir} do
    for {opts, classes} <- [
          {[], "19"},
          {[classes: 3], "3"},
          {[performance: :sustained_high_performance],
           "19 --performance sustained_high_performance"},
          {[rpc_polling_us: 500], "19 --rpc-polling-us 500"}
        ] do
      start_backend(dir, "answer", opts)
      eventually(&Qnn.available?/0)
      assert Qnn.segment(1, @band) == :ok
      assert_receive {:inference_labels, 1, %{}}, 2_000

      assert [arguments] = dir |> Path.join("cache/*.bin.arguments") |> Path.wildcard()
      assert File.read!(arguments) == classes
      stop_supervised!(Qnn)
      File.rm!(arguments)
    end
  end

  test "an empty label image is no labels, and leaves the Port open for the next band", %{
    tmp_dir: dir
  } do
    start_backend(dir, "fail")
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert_receive {:inference_labels, 1, nil}, 2_000
    assert Qnn.segment(2, @band) == :ok
    assert_receive {:inference_labels, 2, nil}, 2_000
    assert Qnn.inference_times() == nil
    assert [starts] = dir |> Path.join("cache/*.bin.starts") |> Path.wildcard()
    assert File.read!(starts) == "start\n"
  end

  test "a label image shorter than its size is no labels, said once", %{tmp_dir: dir} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "short")
        eventually(&Qnn.available?/0)

        assert Qnn.segment(1, @band) == :ok
        assert_receive {:inference_labels, 1, nil}, 2_000
        assert Qnn.segment(2, @band) == :ok
        assert_receive {:inference_labels, 2, nil}, 2_000
      end)

    assert length(String.split(log, "qnn_segment sent a packet that is cut short")) == 2
  end

  test "sums the inference times the replies carry and starts over once they are read", %{
    tmp_dir: dir
  } do
    start_backend(dir, "answer")
    eventually(&Qnn.available?/0)

    for sequence <- [1, 2] do
      assert Qnn.segment(sequence, @band) == :ok
      assert_receive {:inference_labels, ^sequence, %{}}, 2_000
    end

    assert Qnn.inference_times() == %{sum_us: 5_000, count: 2}
    assert Qnn.inference_times() == %{sum_us: 0, count: 0}
  end

  test "reports no inference times while the replies carry none", %{tmp_dir: dir} do
    start_backend(dir, "answer_untimed")
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert_receive {:inference_labels, 1, %{width: 4}}, 2_000
    assert Qnn.inference_times() == nil
  end

  test "reports no inference times once the Port went down, and reopens it", %{tmp_dir: dir} do
    start_backend(dir, "answer_once", reopen_delays_ms: [200])
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert_receive {:inference_labels, 1, %{}}, 2_000
    eventually(fn -> not Qnn.available?() end)
    assert Qnn.inference_times() == nil
    assert Qnn.segment(2, @band) == {:error, :unavailable}
    eventually(&Qnn.available?/0)
  end

  test "busy while a band is in flight; one left unanswered is no labels, and the Port restarted",
       %{tmp_dir: dir} do
    start_backend(dir, "hang", infer_timeout_ms: 200)
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert Qnn.segment(2, @band) == {:error, :busy}
    assert_receive {:inference_labels, 1, nil}, 1_000
    eventually(fn -> Qnn.segment(3, @band) == :ok end)
  end

  test "a band in flight when the Port exits is no labels", %{tmp_dir: dir} do
    start_backend(dir, "die", reopen_delays_ms: [60_000])
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert_receive {:inference_labels, 1, nil}, 2_000
  end

  test "answers at once, unavailable, while its context binary is generated, then opens the Port",
       %{tmp_dir: dir} do
    hold = Path.join(dir, "qairt/bin/hold")
    File.mkdir_p!(Path.dirname(hold))
    File.write!(hold, "")
    on_exit(fn -> File.rm(hold) end)
    start_backend(dir, "answer")

    submitted = Task.async(fn -> Qnn.segment(1, @band) end)
    assert Task.yield(submitted, 500) == {:ok, {:error, :unavailable}}
    refute Qnn.available?()
    assert Qnn.state() == :starting

    File.rm!(hold)
    eventually(&Qnn.available?/0)
    assert Qnn.state() == :running
    assert Qnn.segment(2, @band) == :ok
    assert_receive {:inference_labels, 2, %{}}, 2_000
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
    assert Qnn.segment(1, @band) == :ok
  end

  test "does not try again without its DLC", %{tmp_dir: dir} do
    dlc = Path.join(dir, "late.dlc")

    start_supervised!(
      {Qnn,
       dlc_path: dlc,
       qairt_dir: Path.join(dir, "qairt"),
       cache_dir: Path.join(dir, "cache"),
       executable: @segmenter,
       reopen_delays_ms: [0],
       pipeline: :road}
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

    assert log =~ "#{inspect(Qnn)} (road) unavailable"
    assert Qnn.segment(1, @band) == {:error, :unavailable}
  end

  test "refuses at start an :infer_timeout_ms, :reopen_delays_ms, :performance or :rpc_polling_us it cannot use",
       %{tmp_dir: dir} do
    profiles = "one of [:burst, :sustained_high_performance, :balanced, :power_saver, :none]"

    for {key, value, expected} <- [
          {:performance, :turbo, profiles},
          {:rpc_polling_us, 10_000, "an integer from 0 to 9999"},
          {:infer_timeout_ms, 0, "a positive integer"},
          {:infer_timeout_ms, 1.5, "a positive integer"},
          {:reopen_delays_ms, [], "a non-empty list of non-negative integers"},
          {:reopen_delays_ms, [1_000, -1], "a non-empty list of non-negative integers"},
          {:reopen_delays_ms, 1_000, "a non-empty list of non-negative integers"}
        ] do
      assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
               start_supervised(
                 {Qnn,
                  [
                    {key, value}
                    | [
                        dlc_path: Path.join(dir, "model.dlc"),
                        executable: @segmenter,
                        pipeline: :road
                      ]
                  ]}
               )

      assert message == "its #{inspect(key)} is #{expected}, got #{inspect(value)}"
    end
  end

  test "runs on the Hexagon" do
    assert Qnn.npu_kind() == "Hexagon"
  end

  test "registers under its name and declares its pipeline's inference step", %{tmp_dir: dir} do
    start_supervised!({VisionCore.Parameters, store: VisionCore.Parameters.MemoryStore})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_backend(dir, "answer", name: VisionCore.Pipelines.server(Qnn, :road))
        eventually(fn -> Qnn.available?(VisionCore.Pipelines.server(Qnn, :road)) end)
      end)

    assert log =~ "#{inspect(Qnn)} (road) loaded model.dlc"
    refute Process.whereis(Qnn)

    assert %{pipeline: :road, position: 102, parameters: parameters} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))

    assert Enum.map(parameters, &{&1.name, &1.value, &1.applies}) == [
             {"model", "model.dlc", :build},
             {"classes", 19, :build},
             {"performance", "burst", :build},
             {"rpc_polling_us", 0, :build},
             {"infer_timeout_ms", 2000, :build}
           ]
  end

  test "keeps its context binary in a directory of its pipeline's", %{tmp_dir: dir} do
    backend =
      start_supervised!(
        {Qnn, dlc_path: Path.join(dir, "missing.dlc"), executable: @segmenter, pipeline: :road}
      )

    assert :sys.get_state(backend).settings.cache_dir == "/data/vision/qnn/road"
  end

  test "a missing DLC or QAIRT leaves the backend unavailable", %{tmp_dir: dir} do
    backend =
      start_supervised!(
        {Qnn,
         dlc_path: Path.join(dir, "missing.dlc"),
         qairt_dir: Path.join(dir, "no-qairt"),
         cache_dir: dir,
         pipeline: :road,
         executable: @segmenter}
      )

    refute Qnn.available?()
    assert Qnn.segment(1, @band) == {:error, :unavailable}
    assert Qnn.inference_times() == nil
    assert Process.alive?(backend)
  end
end
