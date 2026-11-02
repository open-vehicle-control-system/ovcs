defmodule VisionCore.Detection.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Pipeline

  # Stands in for the stereo pipeline: tells the test who registers on it.
  defmodule StereoPipeline do
    use GenServer

    def start_link(test),
      do: GenServer.start_link(__MODULE__, test, name: VisionCore.Stereo.Pipeline)

    def init(test), do: {:ok, test}

    def handle_cast({:register_listener, listener}, test) do
      send(test, {:registered, listener})
      {:noreply, test}
    end
  end

  test "registers on the stereo pipeline again once it restarts, and waits for one that is not up yet" do
    detection = start_supervised!({Pipeline, backend: VisionCore.Detection.Backend.Stub})
    refute_receive {:registered, _}, 100

    start_supervised!({StereoPipeline, self()})
    assert_receive {:registered, ^detection}, 1_000

    stop_supervised!(StereoPipeline)
    start_supervised!({StereoPipeline, self()})
    assert_receive {:registered, ^detection}, 1_000
  end

  describe "a pair through the backend" do
    alias VisionCore.Detection.Backend.Stub
    alias VisionCore.Stereo.Pair

    @moduletag :capture_log

    # 40x20 pixels: the left half 2 m away, the right half without depth.
    defp pair_with_depth do
      {width, height} = {40, 20}

      depth =
        for _y <- 1..height,
            x <- 0..(width - 1),
            into: <<>>,
            do: <<if(x < 20, do: 2000, else: 0)::little-16>>

      %Pair{
        left_frame: nil,
        right_frame: nil,
        left: Nx.broadcast(Nx.u8(0), {height, width}),
        depth: depth,
        geometry: %{principal_point: {20.0, 10.0}, focal_length_px: 50.0}
      }
    end

    defp start_detection(boxes, opts) do
      start_supervised!({Stub, boxes: boxes})
      start_supervised!({Pipeline, [backend: Stub] ++ opts})
      Pipeline.register_listener(Pipeline, self())
    end

    defp detections do
      GenServer.cast(Pipeline, {:stereo_pair, pair_with_depth()})
      assert_receive {:"$gen_cast", {:detections, %Pair{}, detections}}, 1_000
      detections
    end

    test "places each box at its depth, dropping one without depth or below the score floor" do
      start_detection(
        [
          {0, 0.9, {0.0, 0.0, 0.5, 1.0}},
          {2, 0.8, {0.5, 0.0, 1.0, 1.0}},
          {1, 0.3, {0.0, 0.0, 0.5, 1.0}}
        ],
        min_score: 0.5
      )

      assert [%{label: "person", class_id: 0, score: 0.9} = person] = detections()
      assert_in_delta person.z, 2.0, 1.0e-6
      assert_in_delta person.x, -0.4, 1.0e-6
    end

    test "keeps the highest scores, up to :max_detections" do
      start_detection(
        [{1, 0.5, {0.0, 0.0, 0.5, 1.0}}, {0, 0.9, {0.0, 0.0, 0.5, 1.0}}],
        max_detections: 1
      )

      assert [%{label: "person"}] = detections()
    end

    test "detects on every :detect_every_n-th pair" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], detect_every_n: 2)

      GenServer.cast(Pipeline, {:stereo_pair, pair_with_depth()})
      refute_receive {:"$gen_cast", {:detections, _pair, _detections}}, 200
      assert [_person] = detections()
    end
  end

  test "declares the steps around the inference, in the detection pipeline, their settings fixed at start" do
    state = %{detect_every_n: 2, min_score: 0.5, max_detections: 10, depth_sample_fraction: 0.25}
    groups = Pipeline.groups(state)

    assert Enum.map(groups, &{&1.id, &1.name, &1.position}) == [
             {"detection.input", "Input", 101},
             {"detection.filtering", "Filtering", 103},
             {"detection.placement", "Placement", 104}
           ]

    for group <- groups do
      assert %{kind: :stage, pipeline: :detection, compute: %{runs_on: :cpu}} = group
      assert group.summary != "" and group.explanation != ""
    end

    parameters = Enum.flat_map(groups, & &1.parameters)

    assert Enum.map(parameters, &{&1.name, &1.type, &1.applies, &1.get.()}) == [
             {"detect_every_n", :integer, :build, 2},
             {"min_score", :double, :build, 0.5},
             {"max_detections", :integer, :build, 10},
             {"depth_sample_fraction", :double, :build, 0.25}
           ]

    refute Enum.any?(parameters, &(&1.description == "Fixed at start"))
  end

  test "the inference step, which its backend declares, sits between the input and the filtering" do
    assert %{
             id: "detection.inference",
             name: "Inference",
             kind: :stage,
             pipeline: :detection,
             position: 102,
             summary: "Infers"
           } = Pipeline.inference_group(%{summary: "Infers", parameters: []})
  end
end
