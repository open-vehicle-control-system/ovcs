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
    def options, do: []
    def inference_times(_server), do: nil
  end

  # Tells the test each sequence it is handed and answers what the test scripted, `:ok` once the
  # script is spent; never replies, the test does.
  defmodule Scripted do
    @behaviour VisionCore.Detection.Backend

    def detect({test, script}, sequence, _image) do
      send(test, {:submitted, sequence})

      Agent.get_and_update(script, fn
        [answer | rest] -> {answer, rest}
        [] -> {:ok, []}
      end)
    end

    def available?(_server), do: true
    def npu_kind, do: nil
    def options, do: []
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
      :ok = Outputs.subscribe({:detections, :detection})
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
      assert_receive {:"$gen_cast", {{:detections, :detection}, {%Pair{}, detections}}}, 1_000
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
      :ok = Outputs.subscribe({:detections, :detection})

      publish_pair()
      refute_receive {:"$gen_cast", {{:detections, :detection}, {_pair, _detections}}}, 100

      assert [%{label: "person"}] = detections()
    end

    test "submits no pair while one is in flight, so its reply is published" do
      script = start_supervised!({Agent, fn -> [] end})
      start_supervised!({Pipeline, backend: Scripted, backend_server: {self(), script}})
      :ok = Outputs.subscribe({:detections, :detection})

      publish_pair()
      assert_receive {:submitted, in_flight}
      publish_pair()
      refute_receive {:submitted, _sequence}, 100

      send(
        GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection)),
        {:inference_detections, in_flight, []}
      )

      assert_receive {:"$gen_cast", {{:detections, :detection}, {%Pair{}, []}}}, 1_000
      publish_pair()
      assert_receive {:submitted, _next}
    end

    test "drops a late reply to a pair the backend refused, matching only the pair it took" do
      script = start_supervised!({Agent, fn -> [{:error, :unavailable}, :ok] end})
      start_supervised!({Pipeline, backend: Scripted, backend_server: {self(), script}})
      :ok = Outputs.subscribe({:detections, :detection})

      publish_pair()
      assert_receive {:submitted, refused}
      publish_pair()
      assert_receive {:submitted, taken}

      send(
        GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection)),
        {:inference_detections, refused, []}
      )

      refute_receive {:"$gen_cast", {{:detections, :detection}, {_pair, _detections}}}, 100

      send(
        GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection)),
        {:inference_detections, taken, []}
      )

      assert_receive {:"$gen_cast", {{:detections, :detection}, {%Pair{}, []}}}, 1_000
    end

    test "times each step of a pair, its inference from the image handed over to the reply" do
      script = start_supervised!({Agent, fn -> [] end})
      clock = start_supervised!(%{id: :clock, start: {Agent, :start_link, [fn -> 0 end]}})

      start_supervised!(
        {Pipeline,
         backend: Scripted,
         backend_server: {self(), script},
         clock: fn -> Agent.get(clock, & &1) end}
      )

      :ok = Outputs.subscribe({:detections, :detection})
      pipeline = VisionCore.Pipelines.server(Pipeline, :detection)

      publish_pair()
      assert_receive {:submitted, in_flight}
      _handed_over = :sys.get_state(pipeline)
      Agent.update(clock, fn _now_ns -> 7_000_000 end)
      send(GenServer.whereis(pipeline), {:inference_detections, in_flight, []})
      assert_receive {:"$gen_cast", {{:detections, :detection}, {%Pair{}, []}}}, 1_000

      assert Pipeline.stage_times(pipeline) == %{
               input: {0.0, 1},
               inference: {7.0, 1},
               filtering: {0.0, 1},
               placement: {0.0, 1}
             }
    end

    test "starts its steps' times over once they are taken, and times no pair the backend refused" do
      script = start_supervised!({Agent, fn -> [{:error, :unavailable}] end})
      start_supervised!({Pipeline, backend: Scripted, backend_server: {self(), script}})
      pipeline = VisionCore.Pipelines.server(Pipeline, :detection)
      none = VisionCore.StageTimes.new([:input, :inference, :filtering, :placement])

      publish_pair()
      assert_receive {:submitted, _refused}
      assert Pipeline.stage_times(pipeline) == none

      publish_pair()
      assert_receive {:submitted, taken}
      send(GenServer.whereis(pipeline), {:inference_detections, taken, []})

      assert %{inference: {_sum_ms, 1}} = Pipeline.stage_times(pipeline)
      assert Pipeline.stage_times(pipeline) == none
    end

    test "ignores a stray :pair_wait on the stereo source" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], [])
      publish_pair()
      send(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection)), :pair_wait)

      assert [%{label: "person"}] = detections()
      assert Process.alive?(GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection)))
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
      refute_receive {:"$gen_cast", {{:detections, :detection}, {_pair, _detections}}}, 200
      assert [_person] = detections()
    end

    test "a named pipeline infers on its own backend and publishes under its own key, its name in the message" do
      start_supervised!(
        Supervisor.child_spec(
          {Stub, name: VisionCore.Pipelines.server(Stub, :road), pipeline: :road, boxes: []},
          id: :road_stub
        )
      )

      start_supervised!(
        {Pipeline,
         name: :road, backend: Stub, backend_server: VisionCore.Pipelines.server(Stub, :road)}
      )

      :ok = Outputs.subscribe({:detections, :road})

      publish_pair()

      assert_receive {:"$gen_cast", {{:detections, :road}, {%Pair{}, []}}}, 1_000
      assert GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :road))
      refute GenServer.whereis(VisionCore.Pipelines.server(Pipeline, :detection))
    end

    test "two pipelines side by side each publish only under their own key" do
      start_detection([{0, 0.9, {0.0, 0.0, 0.5, 1.0}}], [])

      start_supervised!(
        Supervisor.child_spec(
          {Stub, name: VisionCore.Pipelines.server(Stub, :road), pipeline: :road, boxes: []},
          id: :road_stub
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Pipeline,
           name: :road, backend: Stub, backend_server: VisionCore.Pipelines.server(Stub, :road)},
          id: :road_pipeline
        )
      )

      road_listener = self()

      spawn_link(fn ->
        :ok = Outputs.subscribe({:detections, :road})
        send(road_listener, :subscribed)
        receive do: ({:"$gen_cast", message} -> send(road_listener, {:road, message}))
      end)

      assert_receive :subscribed
      publish_pair()

      assert_receive {:"$gen_cast", {{:detections, :detection}, {%Pair{}, [%{label: "person"}]}}},
                     1_000

      assert_receive {:road, {{:detections, :road}, {%Pair{}, []}}}, 1_000
      refute_receive {:"$gen_cast", {{:detections, :road}, {_pair, _detections}}}, 100
    end
  end

  test "declares the steps around the inference, in the detection pipeline, with the stereo source's settings, live" do
    groups =
      Pipeline.groups(
        Pipeline.settings(
          detect_every_n: 2,
          min_score: 0.5,
          max_detections: 10,
          depth_sample_fraction: 0.25,
          outline_segments: 6
        )
      )

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

    assert Enum.map(parameters, &{&1.name, &1.type, &1.constraint, &1.default}) == [
             {"detect_every_n", :integer, range(1, 1000), 2},
             {"min_score", :double, range(0, 1), 0.5},
             {"max_detections", :integer, range(0, 1000), 10},
             {"depth_sample_fraction", :double, range(0.05, 1), 0.25},
             {"outline_segments", :integer, range(1, 32), 6}
           ]

    refute Enum.any?(parameters, &Map.has_key?(&1, :applies))
  end

  test "a camera source's placement has the reprojection stride and the wait for the pair, not the outline" do
    placement =
      [source: {:camera, :hq}]
      |> Pipeline.settings()
      |> Pipeline.groups()
      |> List.last()

    assert Enum.map(placement.parameters, &{&1.name, &1.type, &1.constraint, &1.default}) == [
             {"depth_sample_fraction", :double, range(0.05, 1), 0.5},
             {"reprojection_stride", :integer, range(1, 32), 3},
             {"pair_wait_ms", :integer, range(0, 60_000), 500}
           ]
  end

  test "its groups read and set the process that declares them, not the one of its name" do
    [input | _steps] = Pipeline.groups(Pipeline.settings(name: :road))
    [detect_every_n] = input.parameters

    task = Task.async(fn -> {detect_every_n.set.(3), input.values.()} end)

    assert_receive {:"$gen_call", from, {:put_setting, :detect_every_n, 3}}
    GenServer.reply(from, :ok)
    assert_receive {:"$gen_call", from, :live_settings}
    GenServer.reply(from, %{"detect_every_n" => 3})

    assert Task.await(task) == {:ok, %{"detect_every_n" => 3}}
  end

  test "a setting's type is its spec's, whatever the composer's spelling of its value" do
    settings = Pipeline.settings(min_score: 1, depth_sample_fraction: 1)

    assert settings.min_score === 1.0
    assert settings.depth_sample_fraction === 1.0
  end

  defp range(min, max), do: %{kind: :range, min: min, max: max, step: nil}

  describe "with the parameters registry" do
    alias VisionCore.Detection.Backend.Stub
    alias VisionCore.Parameters.MemoryStore

    @describetag :capture_log

    # One box scoring 0.99 on the left half, where `pair_with_depth/0` has depth.
    @box {0, 0.99, {0.1, 0.1, 0.4, 0.9}}

    defp start_with_registry(saved, opts \\ []) do
      start_supervised!({MemoryStore, saved})
      start_supervised!({VisionCore.Parameters, store: MemoryStore})
      start_supervised!({Stub, boxes: [@box]})
      pipeline = start_supervised!({Pipeline, [backend: Stub] ++ opts})
      :ok = Outputs.subscribe({:detections, :detection})
      # The pipeline declares once it runs; the registry then applies the saved values.
      :sys.get_state(pipeline)
      :sys.get_state(VisionCore.Parameters)
      pipeline
    end

    defp detections_of(pipeline) do
      GenServer.cast(pipeline, {:stereo_pair, pair_with_depth()})
      assert_receive {:"$gen_cast", {{:detections, :detection}, {_pair, detections}}}, 1_000
      detections
    end

    test "lists each setting with the value the pipeline runs with" do
      start_with_registry(%{}, min_score: 0.5)

      assert {:ok, %{value: 0.5, default: 0.5, applies: :live, state: :builtin}} =
               VisionCore.Parameters.get("detection.filtering.min_score")

      assert {:ok, %{value: 4, applies: :live}} =
               VisionCore.Parameters.get("detection.placement.outline_segments")
    end

    test "a setting changed through its parameter applies from the next pair" do
      pipeline = start_with_registry(%{})
      assert [%{label: "person"}] = detections_of(pipeline)

      assert {:ok, %{value: 1.0, state: :unsaved}} =
               VisionCore.Parameters.set("detection.filtering.min_score", 1.0)

      assert detections_of(pipeline) == []
    end

    test "a saved setting reaches a pipeline as it starts" do
      pipeline = start_with_registry(%{"detection.filtering.max_detections" => 0})

      assert {:ok, %{value: 0, default: 20, state: :saved}} =
               VisionCore.Parameters.get("detection.filtering.max_detections")

      assert detections_of(pipeline) == []
    end

    test "detect_every_n and the outline's segments change while it runs" do
      pipeline = start_with_registry(%{})
      assert [%{outline: outline}] = detections_of(pipeline)
      assert length(outline) == 16

      assert {:ok, _} = VisionCore.Parameters.set("detection.placement.outline_segments", 2)
      assert [%{outline: outline}] = detections_of(pipeline)
      assert length(outline) == 8

      assert {:ok, _} = VisionCore.Parameters.set("detection.input.detect_every_n", 2)
      # Pairs 1 and 2 were detected on: the third is skipped, the fourth detected on.
      GenServer.cast(pipeline, {:stereo_pair, pair_with_depth()})
      refute_receive {:"$gen_cast", {{:detections, :detection}, _result}}, 100
      assert [%{label: "person"}] = detections_of(pipeline)
    end

    test "a value outside a setting's range is refused, and the pipeline keeps its value" do
      start_with_registry(%{})

      assert {:error, "must be from 1 to 1000, got 0"} =
               VisionCore.Parameters.set("detection.input.detect_every_n", 0)

      assert Pipeline.put_setting(:detection, :min_score, 3) ==
               {:error, "min_score must be from 0 to 1, got 3"}

      assert Pipeline.live_settings(:detection)["min_score"] == 0.4
    end
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
    state = Pipeline.settings(name: :road)

    groups = Pipeline.groups(state) ++ [Pipeline.inference_group(:road, %{parameters: []})]

    assert Enum.map(groups, &{&1.id, &1.pipeline, &1.position}) == [
             {"road.input", :road, 101},
             {"road.filtering", :road, 103},
             {"road.placement", :road, 104},
             {"road.inference", :road, 102}
           ]
  end

  test "refuses at start an option whose value it cannot run with" do
    Process.flag(:trap_exit, true)

    for {option, refused} <- [
          {{:detect_every_n, 0}, "its :detect_every_n must be from 1 to 1000, got 0"},
          {{:detect_every_n, 1.5}, "its :detect_every_n must be an integer, got 1.5"},
          {{:max_detections, -1}, "its :max_detections must be from 0 to 1000, got -1"},
          {{:reprojection_stride, 0}, "its :reprojection_stride must be from 1 to 32, got 0"},
          {{:pair_wait_ms, -1}, "its :pair_wait_ms must be from 0 to 60000, got -1"},
          {{:min_score, "0.4"}, "its :min_score must be a number, got \"0.4\""},
          {{:depth_sample_fraction, 0},
           "its :depth_sample_fraction must be from 0.05 to 1, got 0"},
          {{:outline_segments, 0}, "its :outline_segments must be from 1 to 32, got 0"}
        ] do
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Pipeline.start_link([option, backend: VisionCore.Detection.Backend.Stub])

      assert message == refused
    end
  end
end
