defmodule VisionCore.Stereo.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{NativeSegment, NxSegment, Pipeline}
  alias VisionCore.Stereo.Stage

  @calibration Path.expand("../../support/calibration", __DIR__)

  # A CPU stage with a runtime setting and a build setting.
  defmodule Gain do
    @behaviour VisionCore.Stereo.Stage

    def init(opts, _context),
      do: {:ok, %{gain: Keyword.get(opts, :gain, 1), size: Keyword.get(opts, :size, 3)}}

    def requires, do: [:depth]
    def provides, do: [:depth]
    def run(pair, state), do: {:ok, pair, state}

    def option_specs,
      do: [
        gain: %{type: :integer, range: {1, 10}},
        size: %{type: :integer, values: [3, 5], applies: :build}
      ]

    def options(state), do: %{gain: state.gain, size: state.size}

    def set_option(state, :gain, gain) when gain in 1..10, do: {:ok, %{state | gain: gain}}
    def set_option(_state, :gain, gain), do: {:error, "gain out of range: #{inspect(gain)}"}
  end

  # A CPU stage between two native runs.
  defmodule Gain2D do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]
    def run(pair, state), do: {:ok, %{pair | disparity: Nx.multiply(pair.disparity, 1.0)}, state}
  end

  # A compiled stage that keeps the device busy and whose results take a while to collect.
  defmodule SlowFinish do
    @behaviour VisionCore.Stereo.NxStage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:disparity]
    def provides, do: [:disparity]
    def params(_state, _context), do: %{}

    def step(tensors, _params, _state) do
      busy = Nx.iota({2_500, 2_500}, type: :f32)
      busy = busy |> Nx.dot(busy) |> Nx.sum() |> Nx.multiply(0)
      Map.update!(tensors, :disparity, &Nx.add(&1, busy))
    end

    def finish(pair, _outputs, _state) do
      Process.sleep(200)
      pair
    end
  end

  defp start(stages, opts \\ []) do
    Pipeline.start_link(
      [
        name: :pipeline_test,
        stages: stages,
        left_calibration_path: Path.join(@calibration, "stereo_left.yaml"),
        right_calibration_path: Path.join(@calibration, "stereo_right.yaml"),
        width: 64,
        height: 48
      ] ++ opts
    )
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "starts with the default stages" do
    assert {:ok, _pipeline} = start(Pipeline.default_stages())
  end

  test "refuses a stage whose inputs no stage before it provides" do
    stages = [Stage.Disparity, Stage.Decode, Stage.Depth]

    assert {:error, {%ArgumentError{message: message}, _}} = start(stages)
    assert message =~ "Disparity"
  end

  test "refuses a stage list that never produces depth" do
    assert {:error, {%ArgumentError{message: message}, _}} =
             start([Stage.Decode, Stage.Disparity])

    assert message =~ "depth"
  end

  defp without_compute(stages), do: Enum.map(stages, &Map.delete(&1, :compute))

  test "default_stages/1 passes overrides to the stage they name" do
    stages =
      Pipeline.default_stages(disparity: [num_disparities: 128], point_cloud: [decimation: 2])

    assert {Stage.Disparity, [num_disparities: 128]} in stages
    assert {Stage.PointCloud, [decimation: 2]} in stages
  end

  test "lists each stage's settings and values in pipeline order" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])
    stages = Pipeline.stage_options(pipeline)

    assert Enum.map(stages, & &1.stage) == [
             :rectification,
             :sharpness,
             :disparity,
             :median_filter,
             :speckle_filter,
             :row_alignment,
             :temporal_filter,
             :depth,
             :point_cloud,
             :quality,
             :gain
           ]

    assert [
             %{
               stage: :rectification,
               module: Stage.Rectification,
               summary: "" <> _,
               specs: [right_row_offset: _]
             }
             | _
           ] = stages

    assert %{specs: [], values: %{}} = Enum.find(stages, &(&1.stage == :depth))

    for stage <- Enum.drop(stages, -1),
        do: assert(stage.compute == %{runs_on: :cpu, implementation: :nx, backend: :exla})

    assert List.last(stages).compute == %{runs_on: :cpu, implementation: :elixir, backend: nil}

    assert %{
             module: Gain,
             summary: "",
             specs: [gain: %{applies: :live}, size: %{applies: :build}],
             values: %{gain: 1, size: 3}
           } = List.last(stages)
  end

  test "sets a stage's live settings by stage" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])

    assert {:ok, %{gain: 3, size: 3}} = Pipeline.set_options(pipeline, :gain, gain: 3)

    assert %{values: %{gain: 3}} =
             Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :gain))
  end

  test "refuses a build setting, an unknown stage or setting, and an invalid value, changing nothing" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])

    assert {:error, "gain.size" <> _} = Pipeline.set_options(pipeline, :gain, gain: 2, size: 5)
    assert {:error, "no stereo stage" <> _} = Pipeline.set_options(pipeline, :nope, gain: 2)
    assert {:error, "gain.block_size" <> _} = Pipeline.set_options(pipeline, :gain, block_size: 7)

    assert {:error, "gain out of range" <> _} =
             Pipeline.set_options(pipeline, :gain, gain: 2, gain: 20)

    assert {:error, "disparity.paths" <> _} = Pipeline.set_options(pipeline, :disparity, paths: 3)

    assert {:error, "p2 must exceed p1" <> _} =
             Pipeline.set_options(pipeline, :disparity, p1: 4, p1: 70)

    values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
    assert values.gain == %{gain: 1, size: 3}
    assert %{p1: 8, paths: 8} = values.disparity
  end

  test "changes the match penalties without compiling again" do
    {:ok, pipeline} = start(Pipeline.default_stages())
    [%{state: segment}] = segments(pipeline)

    assert {:ok, %{p1: 4, p2: 40, uniqueness: 1.2}} =
             Pipeline.set_options(pipeline, :disparity, p1: 4, p2: 40, uniqueness: 1.2)

    [%{state: changed}] = segments(pipeline)
    assert changed.function == segment.function
    match = Enum.find(changed.params, fn {_index, params} -> Map.has_key?(params, :p1) end)
    assert {_index, %{p1: p1, p2: p2} = params} = match
    assert params |> Map.keys() |> Enum.sort() == [:p1, :p2, :uniqueness]
    assert {Nx.to_number(p1), Nx.to_number(p2)} == {4.0, 40.0}

    assert {:error, "p2 must exceed p1" <> _} = Pipeline.set_options(pipeline, :disparity, p1: 40)

    assert {:error, "p1 and p2 must be integers" <> _} =
             Pipeline.set_options(pipeline, :disparity, p2: 100)

    assert %{values: %{p1: 4}} =
             Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :disparity))
  end

  defp segments(pipeline),
    do: :sys.get_state(pipeline).stages |> Enum.filter(&(&1.module == NxSegment))

  describe "with a compiled segment first" do
    defp textured_pair(seed) do
      {texture, _key} =
        Nx.Random.randint(Nx.Random.key(seed), 0, 256, shape: {48, 76}, type: :s32)

      texture = Nx.as_type(texture, :u8)

      for {label, image} <- [left: texture[[.., 0..63]], right: texture[[.., 12..75]]] do
        %VisionCore.Camera.Frame{
          label: to_string(label),
          grey: Nx.to_binary(image),
          width: 64,
          height: 48,
          capture_ns: seed
        }
      end
    end

    test "is ready for the next pair before it publishes the previous one" do
      {:ok, pipeline} = start(Pipeline.default_stages())
      Pipeline.register_listener(pipeline, self())

      [left, right] = textured_pair(1)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      refute_received {:"$gen_cast", {:stereo_pair, _}}

      [left, right] = textured_pair(2)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = first}}, 60_000
      assert first.left_frame.capture_ns == 1
      assert_receive :stereo_pipeline_ready, 60_000
    end

    test "publishes the last pair when no other follows" do
      {:ok, pipeline} = start(Pipeline.default_stages())
      Pipeline.register_listener(pipeline, self())

      [left, right] = textured_pair(3)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = pair}}, 1_000
      assert pair.left_frame.capture_ns == 3
    end

    test "publishes pairs taken as soon as it is ready in order, with the results of one at a time" do
      assert_overlapped_matches_one_at_a_time([])
    end

    test "counts device time once while a pair is collected during the next one's device work" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]) ++ [SlowFinish], flush_after_ms: 0)

      Pipeline.register_listener(pipeline, self())
      submit_when_ready(pipeline, [textured_pair(40)])

      start_ms = System.monotonic_time(:millisecond)
      pairs = submit_when_ready(pipeline, Enum.map(41..48, &textured_pair/1))
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      assert pairs |> Enum.map(& &1.device_ms) |> Enum.sum() <= elapsed_ms
    end

    test "does not count the wait for the next pair as device time" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]), flush_after_ms: 5_000)

      Pipeline.register_listener(pipeline, self())
      submit_when_ready(pipeline, [textured_pair(50)])

      [left, right] = textured_pair(51)
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
      Process.sleep(500)
      [left, right] = textured_pair(52)
      Pipeline.submit(pipeline, left, right)

      assert_receive {:"$gen_cast", {:stereo_pair, %{left_frame: %{capture_ns: 51}} = pair}},
                     60_000

      assert pair.device_ms < 500
    end

    test "logs a pair the segment refuses and takes the next one" do
      assert_refused_pair_skipped([])
    end

    test "sends a pair submitted before it is ready once the previous one is back" do
      assert_early_pair_sent_later(2, [])
    end

    test "times the segment under its name" do
      assert_timed(
        [
          :"rectification+sharpness+disparity+median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
        ],
        []
      )
    end
  end

  # Submits each pair once the pipeline is ready for it, as the Pairer does.
  defp submit_when_ready(pipeline, frames) do
    for [left, right] <- frames do
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 60_000
    end

    for _frames <- frames do
      assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
      pair
    end
  end

  defp assert_overlapped_matches_one_at_a_time(opts) do
    frames = Enum.map(10..13, &textured_pair/1)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    one_at_a_time = Enum.flat_map(frames, &submit_when_ready(pipeline, [&1]))
    GenServer.stop(pipeline)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    overlapped = submit_when_ready(pipeline, frames)

    assert Enum.map(overlapped, & &1.left_frame.capture_ns) == Enum.to_list(10..13)

    for {got, want} <- Enum.zip(overlapped, one_at_a_time) do
      assert got.disparity_bytes == want.disparity_bytes
      assert got.depth == want.depth
      assert got.metrics == want.metrics
    end
  end

  # One pair more than the device takes, submitted without waiting for the pipeline to be ready.
  defp assert_early_pair_sent_later(count, opts) do
    frames = Enum.map(30..(30 + count - 1), &textured_pair/1)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    one_at_a_time = Enum.flat_map(frames, &submit_when_ready(pipeline, [&1]))
    GenServer.stop(pipeline)

    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    for [left, right] <- frames, do: Pipeline.submit(pipeline, left, right)

    early =
      for _frames <- frames do
        assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
        pair
      end

    assert Enum.map(early, & &1.left_frame.capture_ns) == Enum.to_list(30..(30 + count - 1))
    assert Enum.map(early, & &1.disparity_bytes) == Enum.map(one_at_a_time, & &1.disparity_bytes)
    assert_receive :stereo_pipeline_ready, 60_000
  end

  defp assert_refused_pair_skipped(opts) do
    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    [left, right] = textured_pair(20)
    small = %{left | width: 32, height: 48, grey: binary_part(left.grey, 0, 32 * 48)}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Pipeline.submit(pipeline, small, small)
        assert_receive :stereo_pipeline_ready, 60_000
        :sys.get_state(pipeline)
      end)

    assert log =~ "frame_size"
    refute_received {:"$gen_cast", {:stereo_pair, _pair}}
    assert [%{left_frame: %{capture_ns: 20}}] = submit_when_ready(pipeline, [[left, right]])
  end

  defp assert_timed(names, opts) do
    {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), opts)
    Pipeline.register_listener(pipeline, self())
    submit_when_ready(pipeline, [textured_pair(21)])
    timed = Map.keys(:sys.get_state(pipeline).timer.stages)

    assert names -- timed == []
  end

  describe "with the native matcher" do
    @describetag :stereo_match

    setup do
      start_supervised!(VisionCore.Stereo.Matcher)
      :ok
    end

    defp names(pipeline), do: Enum.map(:sys.get_state(pipeline).stages, & &1.name)

    defp receive_pair(pipeline, [left, right]) do
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %VisionCore.Stereo.Pair{} = pair}}, 60_000
      pair
    end

    test "runs Disparity between two compiled segments, under its own name and settings" do
      {:ok, compiled} = start(Pipeline.default_stages())
      compiled_options = Pipeline.stage_options(compiled)
      GenServer.stop(compiled)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native]))

      assert names(pipeline) == [
               :"rectification+sharpness",
               :disparity,
               :"median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      options = Pipeline.stage_options(pipeline)
      assert without_compute(options) == without_compute(compiled_options)

      for stage <- options do
        implementation = if stage.stage == :disparity, do: :rust, else: :nx
        assert stage.compute.implementation == implementation
      end
    end

    test "produces a disparity and depth" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native, paths: 3]))
      Pipeline.register_listener(pipeline, self())

      pair = receive_pair(pipeline, textured_pair(5))

      assert %Nx.Tensor{shape: {48, 64}, type: {:f, 32}} = pair.disparity
      assert pair.disparity_scale == 1.0
      assert %{min_disparity: 0, num_disparities: 64, block_size: 9} = pair.disparity_range
      assert pair.disparity |> Nx.greater_equal(0) |> Nx.sum() |> Nx.to_number() > 0
      assert byte_size(pair.depth) == 48 * 64 * 2
    end

    test "applies a live p1 change from the next pair, as NxStereo.sgm/3 would" do
      stages = [Stage.Rectification, {Stage.Disparity, matcher: :native, paths: 3}, Stage.Depth]
      {:ok, pipeline} = start(stages)
      Pipeline.register_listener(pipeline, self())
      frames = textured_pair(6)
      first = receive_pair(pipeline, frames)

      assert {:ok, %{p1: 2}} = Pipeline.set_options(pipeline, :disparity, p1: 2)
      second = receive_pair(pipeline, frames)

      reference = fn p1 ->
        sgm = &NxStereo.sgm(&1, &2, disparities: 64, paths: 3, p1: p1, p2: 64)
        sgm |> Nx.Defn.jit_apply([second.left, second.right], compiler: EXLA) |> Nx.to_binary()
      end

      assert Nx.to_binary(second.disparity) == reference.(2)
      assert Nx.to_binary(first.disparity) == reference.(8)
      assert first.disparity != second.disparity
    end

    test "stays native across a calibration reload" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [matcher: :native]))
      {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)

      assert :ok = Pipeline.reload_calibration(pipeline)
      assert :disparity in names(pipeline)

      assert %{values: %{p1: 5}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :disparity))
    end
  end

  describe "computing natively" do
    @describetag :stereo_match

    setup do
      start_supervised!(VisionCore.Stereo.Matcher)
      :ok
    end

    test "runs the default stages as one native segment, under their names and settings" do
      {:ok, compiled} = start(Pipeline.default_stages())
      compiled_options = Pipeline.stage_options(compiled)
      GenServer.stop(compiled)

      {:ok, pipeline} = start(Pipeline.default_stages(), compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity+median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      options = Pipeline.stage_options(pipeline)
      assert without_compute(options) == without_compute(compiled_options)

      for stage <- options,
          do: assert(stage.compute == %{runs_on: :cpu, implementation: :rust, backend: nil})
    end

    test "fills every field the listeners read" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      Pipeline.register_listener(pipeline, self())

      pair = receive_pair(pipeline, textured_pair(7))

      assert %Nx.Tensor{shape: {48, 64}, type: {:u, 8}} = pair.left
      assert %Nx.Tensor{shape: {48, 64}, type: {:u, 8}} = pair.right
      assert %Nx.Tensor{shape: {48, 64}, type: {:f, 32}} = pair.disparity
      assert pair.disparity_bytes == Nx.to_binary(pair.disparity)
      assert byte_size(pair.depth) == 48 * 64 * 2
      assert {12, 16} = pair.cloud_size
      assert byte_size(pair.cloud) == 12 * 16 * 12
      assert %{left: left, right: right} = pair.sharpness
      assert left > 0 and right > 0

      assert [:valid, :mean_disp, :std_disp, :jitter] -- Enum.map(pair.metrics, &elem(&1, 0)) ==
               []

      assert pair.device_ms > 0
    end

    test "runs a stage without a native implementation between two native segments" do
      stages = List.insert_at(Pipeline.default_stages(), 3, Gain2D)
      {:ok, pipeline} = start(stages, compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness+disparity",
               :gain2_d,
               :"median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      Pipeline.register_listener(pipeline, self())
      assert byte_size(receive_pair(pipeline, textured_pair(8)).depth) == 48 * 64 * 2
    end

    test "compiles a stage that asks for Nx" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [matcher: :nx]), compute: :native)

      assert names(pipeline) == [
               :"rectification+sharpness",
               :disparity,
               :"median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"
             ]

      assert [NativeSegment, NxSegment, NativeSegment] ==
               Enum.map(:sys.get_state(pipeline).stages, & &1.module)
    end

    test "applies a live setting from the next pair, and keeps it across a calibration reload" do
      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      Pipeline.register_listener(pipeline, self())
      frames = textured_pair(9)
      first = receive_pair(pipeline, frames)

      assert {:ok, %{right_row_offset: 2.0}} =
               Pipeline.set_options(pipeline, :rectification, right_row_offset: 2.0)

      second = receive_pair(pipeline, frames)
      assert Nx.to_binary(second.left) == Nx.to_binary(first.left)
      assert Nx.to_binary(second.right[[0..40, ..]]) == Nx.to_binary(first.right[[2..42, ..]])

      assert :ok = Pipeline.reload_calibration(pipeline)

      assert %{values: %{right_row_offset: 2.0}} =
               Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :rectification))

      third = receive_pair(pipeline, frames)
      assert Nx.to_binary(third.right) == Nx.to_binary(second.right)
    end

    test "takes a second pair while the first is at the Port, with the results of one at a time" do
      frames = Enum.map(10..13, &textured_pair/1)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      Pipeline.register_listener(pipeline, self())
      one_at_a_time = Enum.map(frames, &receive_pair(pipeline, &1))
      GenServer.stop(pipeline)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      Pipeline.register_listener(pipeline, self())
      [[left, right] | later] = frames
      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 1_000

      overlapped =
        Enum.map(later, fn [left, right] ->
          Pipeline.submit(pipeline, left, right)

          # The pipeline is ready for another pair once the earlier one is out.
          assert_receive {:"$gen_cast", {:stereo_pair, pair}}, 60_000
          assert_receive :stereo_pipeline_ready, 60_000
          pair
        end)

      assert_receive {:"$gen_cast", {:stereo_pair, last}}, 60_000
      overlapped = overlapped ++ [last]

      assert Enum.map(overlapped, & &1.left_frame.capture_ns) == Enum.to_list(10..13)

      for {got, want} <- Enum.zip(overlapped, one_at_a_time) do
        assert got.disparity_bytes == want.disparity_bytes
        assert got.depth == want.depth
        assert got.metrics == want.metrics
      end
    end

    test "publishes pairs taken as soon as it is ready in order, with the results of one at a time, natively" do
      assert_overlapped_matches_one_at_a_time(compute: :native)
    end

    test "logs a pair the segment refuses and takes the next one, natively" do
      assert_refused_pair_skipped(compute: :native)
    end

    test "sends a pair submitted before it is ready once the oldest one is back" do
      assert_early_pair_sent_later(3, compute: :native)
    end

    test "times the segment and each member under their names" do
      segment =
        :"rectification+sharpness+disparity+median_filter+speckle_filter+row_alignment+temporal_filter+depth+point_cloud+quality"

      members = segment |> to_string() |> String.split("+") |> Enum.map(&String.to_atom/1)
      assert_timed([segment | members], compute: :native)
    end

    test "publishes a pair once it is back when no other is at the Port" do
      {:ok, pipeline} =
        start(Pipeline.default_stages(disparity: [paths: 3]),
          compute: :native,
          flush_after_ms: 60_000
        )

      Pipeline.register_listener(pipeline, self())
      [left, right] = textured_pair(22)
      Pipeline.submit(pipeline, left, right)
      assert_receive {:"$gen_cast", {:stereo_pair, %{left_frame: %{capture_ns: 22}}}}, 10_000
    end

    @tag :tmp_dir
    test "a Port that exits fails the pairs at it, and the next pair is taken", %{tmp_dir: dir} do
      path = Application.get_env(:vision_core, :stereo_match_path)
      on_exit(fn -> Application.put_env(:vision_core, :stereo_match_path, path) end)
      silent = Path.join(dir, "stereo_match")
      File.write!(silent, "#!/bin/sh\nexec cat > /dev/null\n")
      File.chmod!(silent, 0o755)
      Application.put_env(:vision_core, :stereo_match_path, silent)

      {:ok, pipeline} = start(Pipeline.default_stages(disparity: [paths: 3]), compute: :native)
      Pipeline.register_listener(pipeline, self())
      [[left, right], [next_left, next_right], last] = Enum.map(14..16, &textured_pair/1)

      Pipeline.submit(pipeline, left, right)
      assert_receive :stereo_pipeline_ready, 1_000
      Pipeline.submit(pipeline, next_left, next_right)
      refute_receive :stereo_pipeline_ready, 200

      Application.put_env(:vision_core, :stereo_match_path, path)
      {:os_pid, os_pid} = Port.info(:sys.get_state(VisionCore.Stereo.Matcher).port, :os_pid)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)])

      assert_receive :stereo_pipeline_ready, 5_000
      refute_received {:"$gen_cast", {:stereo_pair, _pair}}
      assert receive_pair(pipeline, last).left_frame.capture_ns == 16
    end

    test "refuses an unknown way to compute" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start(Pipeline.default_stages(), compute: :gpu)

      assert message =~ ":nx or :native"
    end
  end

  test "keeps settings changed at runtime across a calibration reload" do
    {:ok, pipeline} = start(Pipeline.default_stages() ++ [Gain])
    {:ok, _} = Pipeline.set_options(pipeline, :gain, gain: 4)
    {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)

    assert :ok = Pipeline.reload_calibration(pipeline)
    values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
    assert %{gain: 4} = values.gain
    assert %{p1: 5} = values.disparity
  end
end
