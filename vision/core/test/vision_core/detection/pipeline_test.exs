defmodule VisionCore.Detection.PipelineTest do
  use ExUnit.Case, async: false

  alias VisionCore.Detection.Pipeline
  alias VisionCore.Outputs

  # Fails the odd frames, as a backend whose Port went down, and finds a person on the left half of
  # the even ones.
  defmodule EveryOtherFrame do
    @behaviour VisionCore.Detection.Backend

    def detect(_server, sequence, image) do
      {height, width} = image |> Nx.shape() |> then(&{elem(&1, 0), elem(&1, 1)})
      person = %{class_id: 0, score: 0.9, x0: 0.0, y0: 0.0, x1: width / 2, y1: height / 1}
      detections = if rem(sequence, 2) == 1, do: nil, else: [person]
      send(self(), {:inference_detections, sequence, detections})
      :ok
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def inference_times(_server), do: nil
  end

  describe "a pair through the backend" do
    alias VisionCore.Camera.Frame
    alias VisionCore.Detection.Backend.Stub
    alias VisionCore.Stereo.Pair

    @moduletag :capture_log

    # Matched at 40x20 pixels, half the frames' size, without calibration: the left half 2 m
    # away, the right half without depth.
    defp pair_with_depth do
      {width, height} = {40, 20}
      frame = %Frame{label: "left", width: 80, height: 40, capture_ns: 0, grey: <<>>}

      depth =
        for _y <- 1..height,
            x <- 0..(width - 1),
            into: <<>>,
            do: <<if(x < 20, do: 2000, else: 0)::little-16>>

      %Pair{
        left_frame: frame,
        right_frame: %Frame{frame | label: "right"},
        left: Nx.broadcast(Nx.u8(0), {height, width}),
        depth: depth,
        geometry: %{principal_point: {20.0, 10.0}, focal_length_px: 50.0}
      }
    end

    defp start_detection(boxes, opts) do
      start_supervised!({Stub, boxes: boxes})
      start_supervised!({Pipeline, [backend: Stub] ++ opts})
      :ok = Outputs.subscribe({:detections, Pipeline})
    end

    # As the stereo pipeline publishes it, which need not be running.
    defp publish_pair,
      do:
        Outputs.publish(
          {:stereo_pair, VisionCore.Stereo.Pipeline},
          {:stereo_pair, pair_with_depth()}
        )

    defp detections do
      publish_pair()
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
      assert length(person.outline) == 16
    end

    test "outlines each box on the captured left frame, and captions it, for every consumer" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], outline_segments: 1)

      assert [person] = detections()
      assert person.outline == [{0.0, 0.0}, {40.0, 0.0}, {40.0, 40.0}, {0.0, 40.0}]
      assert person.caption == "person 0.90 2.00m"
    end

    test "publishes nothing for a pair the backend could not detect on, and detects the next" do
      start_supervised!({Pipeline, backend: EveryOtherFrame})
      :ok = Outputs.subscribe({:detections, Pipeline})

      publish_pair()
      refute_receive {:"$gen_cast", {:detections, _pair, _detections}}, 100

      assert [%{label: "person"}] = detections()
    end

    test "ignores a stray :pair_wait on the stereo source" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], [])
      publish_pair()
      send(Pipeline, :pair_wait)

      assert [%{label: "person"}] = detections()
      assert Process.alive?(Process.whereis(Pipeline))
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

      publish_pair()
      refute_receive {:"$gen_cast", {:detections, _pair, _detections}}, 200
      assert [_person] = detections()
    end

    test "a named pipeline infers on its own backend and publishes under its own key, its name in the message" do
      start_supervised!(
        Supervisor.child_spec({Stub, name: Stub.Road, pipeline: :road, boxes: []}, id: :road_stub)
      )

      start_supervised!({Pipeline, name: :road, backend: Stub, backend_server: Stub.Road})
      :ok = Outputs.subscribe({:detections, Pipeline.Road})

      publish_pair()

      assert_receive {:"$gen_cast", {:detections, %Pair{}, [], :road}}, 1_000
      assert Process.whereis(Pipeline.Road)
      refute Process.whereis(Pipeline)
    end

    test "two pipelines side by side each publish only under their own key" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], [])

      start_supervised!(
        Supervisor.child_spec({Stub, name: Stub.Road, pipeline: :road, boxes: []}, id: :road_stub)
      )

      start_supervised!(
        Supervisor.child_spec(
          {Pipeline, name: :road, backend: Stub, backend_server: Stub.Road},
          id: :road_pipeline
        )
      )

      road_listener = self()

      spawn_link(fn ->
        :ok = Outputs.subscribe({:detections, Pipeline.Road})
        send(road_listener, :subscribed)
        receive do: ({:"$gen_cast", message} -> send(road_listener, {:road, message}))
      end)

      assert_receive :subscribed
      publish_pair()

      assert_receive {:"$gen_cast", {:detections, %Pair{}, [%{label: "person"}]}}, 1_000
      assert_receive {:road, {:detections, %Pair{}, [], :road}}, 1_000
      refute_receive {:"$gen_cast", {:detections, _pair, _detections, :road}}, 100
    end
  end

  test "declares the steps around the inference, in the detection pipeline, their settings fixed at start" do
    state = %{
      name: :detection,
      detect_every_n: 2,
      min_score: 0.5,
      max_detections: 10,
      depth_sample_fraction: 0.25
    }

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
           } = Pipeline.inference_group(:detection, %{summary: "Infers", parameters: []})
  end

  test "a named pipeline's steps carry its name, at the same positions" do
    state = %{
      name: :road,
      detect_every_n: 1,
      min_score: 0.5,
      max_detections: 10,
      depth_sample_fraction: 0.5
    }

    groups = Pipeline.groups(state) ++ [Pipeline.inference_group(:road, %{parameters: []})]

    assert Enum.map(groups, &{&1.id, &1.pipeline, &1.position}) == [
             {"road.input", :road, 101},
             {"road.filtering", :road, 103},
             {"road.placement", :road, 104},
             {"road.inference", :road, 102}
           ]
  end
end
