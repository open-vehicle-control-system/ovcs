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

  test "a label image shorter than its size is no labels", %{tmp_dir: dir} do
    start_backend(dir, "short")
    eventually(&Qnn.available?/0)

    assert Qnn.segment(1, @band) == :ok
    assert_receive {:inference_labels, 1, nil}, 2_000
    assert Qnn.segment(2, @band) == :ok
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

    File.rm!(hold)
    eventually(&Qnn.available?/0)
    assert Qnn.segment(2, @band) == :ok
    assert_receive {:inference_labels, 2, %{}}, 2_000
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

  test "refuses at start an :infer_timeout_ms or :reopen_delays_ms it cannot wait on", %{
    tmp_dir: dir
  } do
    for {key, value, expected} <- [
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
        start_backend(dir, "answer", name: Qnn.Road)
        eventually(fn -> Qnn.available?(Qnn.Road) end)
      end)

    assert log =~ "#{inspect(Qnn)} (road) loaded model.dlc"
    refute Process.whereis(Qnn)

    assert %{pipeline: :road, position: 102, parameters: [model]} =
             Enum.find(VisionCore.Parameters.groups(), &(&1.id == "road.inference"))

    assert model.value == "model.dlc"
  end

  test "keeps its context binary in a directory of its pipeline's", %{tmp_dir: dir} do
    backend =
      start_supervised!(
        {Qnn, dlc_path: Path.join(dir, "missing.dlc"), executable: @segmenter, pipeline: :road}
      )

    assert :sys.get_state(backend).cache_dir == "/data/vision/qnn/road"
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
