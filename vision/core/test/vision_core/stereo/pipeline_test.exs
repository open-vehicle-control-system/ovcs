defmodule VisionCore.Stereo.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.Pipeline
  alias VisionCore.Stereo.Stage

  @calibration Path.expand("../../support/calibration", __DIR__)

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
    assert {:ok, pipeline} = start(Pipeline.default_stages())
    assert Map.has_key?(Pipeline.options(pipeline), :num_disparities)
    assert Map.has_key?(Pipeline.options(pipeline), :clahe)
  end

  test "refuses a stage whose inputs no stage before it provides" do
    stages = [Stage.Sgbm, Stage.Decode, Stage.Depth]

    assert {:error, {%ArgumentError{message: message}, _}} = start(stages)
    assert message =~ "Sgbm"
  end

  test "refuses a stage list that never produces depth" do
    assert {:error, {%ArgumentError{message: message}, _}} = start([Stage.Decode, Stage.Sgbm])
    assert message =~ "depth"
  end

  test "default_stages/1 passes overrides to the stage they name" do
    stages = Pipeline.default_stages(sgbm: [num_disparities: 96])
    assert {Stage.Sgbm, [num_disparities: 96]} in stages

    {:ok, pipeline} = start(stages)
    assert Pipeline.options(pipeline).num_disparities == 96
  end

  test "routes each setting to the stage that declares it" do
    {:ok, pipeline} = start(Pipeline.default_stages())

    assert {:ok, %{uniqueness_ratio: 20, clahe: false}} =
             Pipeline.set_options(pipeline, uniqueness_ratio: 20, clahe: false)

    assert {:error, "unknown or invalid stereo setting" <> _} =
             Pipeline.set_options(pipeline, block_size: 7)
  end

  test "lists only the settings of the stages it runs" do
    stages = Enum.reject(Pipeline.default_stages(), &match?({Stage.Clahe, _}, &1))
    {:ok, pipeline} = start(stages)

    keys = pipeline |> Pipeline.option_specs() |> Keyword.keys()
    assert :uniqueness_ratio in keys
    refute :clahe in keys
  end

  test "keeps settings changed at runtime across a calibration reload" do
    {:ok, pipeline} = start(Pipeline.default_stages())
    {:ok, _} = Pipeline.set_options(pipeline, uniqueness_ratio: 25)

    assert :ok = Pipeline.reload_calibration(pipeline)
    assert Pipeline.options(pipeline).uniqueness_ratio == 25
  end
end
