defmodule VisionCore.Segmentation.SupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Segmentation.Backend.{Qnn, Stub}
  alias VisionCore.Segmentation.{Live, Pipeline, Supervisor}

  @moduletag :capture_log

  @options [
    name: :road,
    backend: Stub,
    source: {:camera, :hq},
    label_image: %{width: 1, height: 1, data: <<0>>},
    max_hz: 4,
    band_top: 0.5,
    road_classes: ["road", "sidewalk"]
  ]

  defp config(components), do: %VisionCore.Config{components: components}

  defp camera_config,
    do: config([{:camera, name: :hq, driver: VisionCore.Camera.GStreamer}])

  test "hands the backend, the pipeline and Live their options, each named after the pipeline" do
    {:ok, {flags, children}} = Supervisor.init(@options)

    assert %{strategy: :rest_for_one} = flags

    assert [
             %{start: {Stub, :start_link, [backend_options]}},
             %{start: {Pipeline, :start_link, [pipeline_options]}},
             %{start: {Live, :start_link, [live_options]}}
           ] = children

    assert Enum.sort(backend_options) == [
             classes: 19,
             label_image: %{width: 1, height: 1, data: <<0>>},
             name: Stub.Road,
             pipeline: :road
           ]

    assert Enum.sort(pipeline_options) == [
             backend: Stub,
             backend_server: Stub.Road,
             band_top: 0.5,
             name: :road,
             road_classes: ["road", "sidewalk"],
             source: {:camera, :hq}
           ]

    assert Enum.sort(live_options) == [max_hz: 4, name: :road]
  end

  test "names a unit's classes and those that are road, the Cityscapes ones and road by default" do
    config = %VisionCore.Config{
      components: [
        {:segmenter, @options},
        {:segmenter, name: :lanes, source: {:camera, :hq}, labels: ["lane", "other"]}
      ]
    }

    assert %{labels: ["road", "sidewalk" | _others], road_classes: ["road", "sidewalk"]} =
             Supervisor.classes(config, :road)

    assert Supervisor.classes(config, :lanes) == %{
             labels: ["lane", "other"],
             road_classes: ["road"]
           }

    assert Supervisor.classes(config, :signs) == nil
  end

  test "tells the backend how many classes its labels name" do
    {:ok, {_flags, [backend | _children]}} =
      Supervisor.init(@options ++ [labels: ["road", "sidewalk", "sky"]])

    assert %{start: {Stub, :start_link, [backend_options]}} = backend
    assert backend_options[:classes] == 3
  end

  test "runs on the QNN backend by default, keeping every QNN option to it" do
    qnn_options = [
      dlc_path: "/model.dlc",
      qairt_dir: "/qairt",
      dsp_library_path: "/dsp",
      dsp_architecture: "hexagon-v79",
      cache_dir: "/cache",
      executable: "/qnn_segment",
      infer_timeout_ms: 100,
      reopen_delays_ms: [10],
      performance: :balanced
    ]

    {:ok, {_flags, [backend | _children]}} =
      Supervisor.init([name: :road, source: {:camera, :hq}] ++ qnn_options)

    assert %{start: {Qnn, :start_link, [backend_options]}} = backend
    assert qnn_options -- backend_options == []
  end

  test "starts the backend, then the pipeline, then Live, registered under its name" do
    unit = start_supervised!({Supervisor, @options ++ [config: camera_config()]})

    assert Process.whereis(Supervisor.Road) == unit

    assert unit |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0)) ==
             [Live, Pipeline, Stub]

    for module <- [Stub, Pipeline, Live], do: assert(Process.whereis(Module.concat(module, Road)))
  end

  test "is left down, saying why, without a name, with an invalid one, or with an option it does not take" do
    Process.flag(:trap_exit, true)

    for {options, reason} <- [
          {Keyword.delete(@options, :name), "a segmenter needs a :name"},
          {Keyword.put(@options, :name, :stereo), "not one of :stereo"},
          {Keyword.put(@options, :name, "road"), "got \"road\""},
          {@options ++ [min_score: 0.5], "no option :min_score"},
          {@options ++ [topic_prefix: "front"],
           ":topic_prefix is the ROS 2 exporter's segmentation: option"}
        ] do
      log = capture_log(fn -> assert Supervisor.start_link(options) == :ignore end)

      assert log =~ "failed to start"
      assert log =~ reason
    end
  end

  test "is left down, saying why, when its pipeline cannot start" do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        assert Supervisor.start_link(@options ++ [config: config([])]) == :ignore
      end)

    assert log =~ "VisionCore.Segmentation.Supervisor.Road failed to start, road down"
    assert log =~ "no camera of the configuration"
  end

  describe "in a configuration" do
    @components [
      {:detector, backend: VisionCore.Detection.Backend.Stub},
      {:qnn_segmenter, name: :road, source: {:camera, :hq}, dlc_path: "/road.dlc"},
      {:segmenter, name: :lane, backend: Stub, source: {:camera, :front}}
    ]

    test "its outputs, keyed by each pipeline's name, in config order" do
      assert Supervisor.outputs(config(@components)) == [
               {{:segmentation, :road}, {:segmentation, Pipeline.Road}},
               {{:segmentation, :lane}, {:segmentation, Pipeline.Lane}}
             ]
    end

    test "its sources, by output" do
      assert Supervisor.sources(config(@components)) == [
               {{:segmentation, :road}, {:camera, :hq}},
               {{:segmentation, :lane}, {:camera, :front}}
             ]
    end

    test "its pipelines on a camera, each with the camera's name, leaving out one without a camera" do
      components =
        @components ++
          [
            {:segmenter, name: :sourceless},
            {:segmenter, name: :kerb, backend: Stub, source: {:camera, :hq, :inference}}
          ]

      assert Supervisor.sources(config(components)) |> Enum.at(2) ==
               {{:segmentation, :sourceless}, nil}

      assert Supervisor.cameras(config(components)) == [road: :hq, lane: :front, kerb: :hq]
    end

    test "its pipelines: each one's name with its backend and server" do
      assert Supervisor.pipelines(config(@components)) == [
               {:road, Qnn, Qnn.Road},
               {:lane, Stub, Stub.Lane}
             ]
    end

    test "none without a segmenter" do
      assert Supervisor.outputs(config([:detector])) == []
      assert Supervisor.pipelines(config([])) == []
    end
  end
end
