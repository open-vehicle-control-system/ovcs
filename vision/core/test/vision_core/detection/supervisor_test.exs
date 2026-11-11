defmodule VisionCore.Detection.SupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Detection.Backend.{Hailo, Stub}
  alias VisionCore.Detection.{Live, Pipeline, Supervisor}

  @moduletag :capture_log

  @options [
    backend: Stub,
    boxes: [{0, 0.9, {0.0, 0.0, 0.5, 0.5}}],
    max_hz: 4,
    outline_segments: 2,
    min_score: 0.6
  ]

  test "hands the backend, the pipeline and Live their options" do
    {:ok, {_flags, children}} = Supervisor.init(@options)

    assert [
             %{start: {Stub, :start_link, [backend_options]}},
             %{start: {Pipeline, :start_link, [pipeline_options]}},
             %{start: {Live, :start_link, [live_options]}}
           ] = children

    assert [boxes: [{0, 0.9, _box}], name: Stub, pipeline: :detection] =
             Enum.sort(backend_options)

    assert Enum.sort(pipeline_options) == [
             backend: Stub,
             backend_server: Stub,
             min_score: 0.6,
             name: :detection,
             outline_segments: 2
           ]

    assert Enum.sort(live_options) == [max_hz: 4, name: :detection]
  end

  test "names a named unit's backend, pipeline and Live after it" do
    {:ok, {_flags, children}} = Supervisor.init(@options ++ [name: :road])

    assert [
             %{start: {Stub, :start_link, [backend_options]}},
             %{start: {Pipeline, :start_link, [pipeline_options]}},
             %{start: {Live, :start_link, [live_options]}}
           ] = children

    assert {backend_options[:name], backend_options[:pipeline]} == {Stub.Road, :road}
    assert {pipeline_options[:name], pipeline_options[:backend_server]} == {:road, Stub.Road}
    assert live_options[:name] == :road
  end

  test "takes an option given twice, as a keyword list may hold it" do
    assert {:ok, {_flags, [_backend, _pipeline, live]}} = Supervisor.init(@options ++ [max_hz: 2])
    assert %{start: {Live, :start_link, [[max_hz: 4, max_hz: 2, name: :detection]]}} = live
  end

  test "starts the backend, then the pipeline, then Live" do
    unit = start_supervised!({Supervisor, @options})

    assert unit |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0)) ==
             [Live, Pipeline, Stub]

    assert Process.whereis(Supervisor) == unit
  end

  test "registers a named unit and its processes under its name, beside the default one" do
    default = start_supervised!({Supervisor, @options})

    road =
      start_supervised!(
        Elixir.Supervisor.child_spec({Supervisor, @options ++ [name: :road]}, id: :road)
      )

    assert Process.whereis(Supervisor.Road) == road
    assert Process.whereis(Supervisor) == default

    for module <- [Stub, Pipeline, Live] do
      assert Process.whereis(Module.concat(module, Road))
      assert Process.whereis(module)
    end
  end

  test "is left down, saying why, with a name that is no valid pipeline name" do
    Process.flag(:trap_exit, true)

    for name <- [:"front-cam", :stereo] do
      log =
        capture_log(fn -> assert Supervisor.start_link(@options ++ [name: name]) == :ignore end)

      assert log =~ "failed to start"
      assert log =~ "^[a-z][a-z0-9_]*$"
      assert log =~ inspect(name)
    end
  end

  test "a named unit that fails to start names its pipeline in the log" do
    Process.flag(:trap_exit, true)

    log =
      capture_log(fn -> assert Supervisor.start_link(backend: Hailo, name: :road) == :ignore end)

    assert log =~ "VisionCore.Detection.Supervisor.Road failed to start, road down"
  end

  test "is left down, saying why, with an option it does not take, naming where a moved one went" do
    Process.flag(:trap_exit, true)

    for {option, reason} <- [
          {[frame_id: "stereo_left_optical"], ":frame_id is the stereo unit's"},
          {[topic_prefix: "front"], ":topic_prefix is the ROS 2 exporter's"},
          {[marker_lifetime_ms: 200], ":marker_lifetime_ms is the ROS 2 exporter's"},
          {[label_font_size: 14.0], ":label_font_size is the ROS 2 exporter's"},
          {[min_scor: 0.6], "no option :min_scor"}
        ] do
      log = capture_log(fn -> assert Supervisor.start_link(@options ++ option) == :ignore end)

      assert log =~ "failed to start, detection down: "
      assert log =~ reason
      refute Process.whereis(Supervisor)
    end
  end

  test "is left down, saying why, when its backend cannot start" do
    Process.flag(:trap_exit, true)
    log = capture_log(fn -> assert Supervisor.start_link(backend: Hailo) == :ignore end)

    assert log =~ "failed to start, detection down"
    assert log =~ "hef_path"
  end

  test "keeps every Hailo option to the backend" do
    assert Supervisor.split_backend_options(
             backend: VisionCore.Detection.Backend.Hailo,
             hef_path: "/models/m.hef",
             executable: "/bin/hailo_detect",
             outline_segments: 2
           ) ==
             {VisionCore.Detection.Backend.Hailo,
              [hef_path: "/models/m.hef", executable: "/bin/hailo_detect"]}
  end

  test "keeps every QNN option to the backend" do
    qnn = [
      dlc_path: "/models/m.dlc",
      qairt_dir: "/opt/qairt",
      dsp_library_path: "/dsp",
      cache_dir: "/data/qnn",
      score_threshold: 0.4
    ]

    assert Supervisor.split_backend_options(
             [backend: VisionCore.Detection.Backend.Qnn, outline_segments: 2] ++ qnn
           ) == {VisionCore.Detection.Backend.Qnn, qnn}
  end

  describe "the detection unit of a config" do
    defp config(components),
      do: %VisionCore.Config{components: components}

    test "its output: the detection pipeline's detections, whichever component starts it" do
      for detector <- [:detector, {:detector, boxes: []}, :hailo_detector, {:hailo_detector, []}] do
        assert Supervisor.outputs(config([detector])) ==
                 [detections: {:detections, VisionCore.Detection.Pipeline}]
      end
    end

    test "none without a component starting it" do
      assert Supervisor.outputs(config([{:stereo, []}])) == []
    end

    test "each pipeline's output, in config order, a named one's keyed by its name" do
      components = [
        {:detector, backend: Stub, name: :road},
        {:stereo, []},
        :qnn_detector,
        {:hailo_detector, name: :signs}
      ]

      assert Supervisor.outputs(config(components)) == [
               {{:detections, :road}, {:detections, VisionCore.Detection.Pipeline.Road}},
               {:detections, {:detections, VisionCore.Detection.Pipeline}},
               {{:detections, :signs}, {:detections, VisionCore.Detection.Pipeline.Signs}}
             ]
    end

    test "its backends: the one each component names, the Hailo one by default, with its server" do
      assert Supervisor.backends(config([{:stereo, []}, :qnn_detector])) ==
               [{VisionCore.Detection.Backend.Qnn, VisionCore.Detection.Backend.Qnn}]

      assert Supervisor.backends(config([{:hailo_detector, hef_path: "/m.hef"}])) ==
               [{Hailo, Hailo}]

      assert Supervisor.backends(config([{:detector, backend: Stub}])) == [{Stub, Stub}]
      assert Supervisor.backends(config([:detector])) == [{Hailo, Hailo}]
    end

    test "each pipeline's backend, in config order, a named one's server named after it" do
      components = [{:detector, backend: Stub, name: :road}, {:hailo_detector, []}]

      assert Supervisor.backends(config(components)) == [{Stub, Stub.Road}, {Hailo, Hailo}]
    end

    test "no backend without a component starting the unit" do
      assert Supervisor.backends(config([{:stereo, []}])) == []
    end
  end
end
