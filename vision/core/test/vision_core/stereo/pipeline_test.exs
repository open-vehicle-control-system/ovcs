defmodule VisionCore.Stereo.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{NxSegment, Pipeline}
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

  defp start(stages) do
    Pipeline.start_link(
      name: :pipeline_test,
      stages: stages,
      left_calibration_path: Path.join(@calibration, "stereo_left.yaml"),
      right_calibration_path: Path.join(@calibration, "stereo_right.yaml"),
      width: 64,
      height: 48
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
