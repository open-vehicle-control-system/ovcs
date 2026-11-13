defmodule VisionCore.StatusTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.{Outputs, Status}
  alias VisionCore.Stereo.Pair

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # An exporter whose status is linked, answered after `delay_ms:`.
  defmodule Exporter do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(_options), do: %{id: :probe, name: "Probe"}

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(options), do: {:ok, options}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, options), do: {:ok, options}

    @impl VisionCore.Exporter
    def status(options) do
      Process.sleep(Keyword.get(options, :delay_ms, 0))
      {:ok, "Linked"}
    end
  end

  defp config(components), do: %VisionCore.Config{components: components}

  defp start_exporter(options) do
    start_supervised!(
      {VisionCore.Exporters, config: config([]), exporters: [{Exporter, options}]}
    )

    {_id, supervisor, :supervisor, _modules} =
      List.keyfind(Supervisor.which_children(VisionCore.Exporters), :probe, 0)

    {_id, runner, :worker, _modules} =
      List.keyfind(Supervisor.which_children(supervisor), VisionCore.Exporter.Runner, 0)

    :sys.get_state(runner)
  end

  defp pair do
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 0, jpeg: <<>>}
    %Pair{left_frame: frame, right_frame: %{frame | label: "right"}}
  end

  test "subscribes to no frames of a camera whose outputs cannot be made" do
    camera = [
      name: :hq,
      driver: VisionCore.Camera.V4L2Single,
      outputs: [view: [resolution: {640, 480}, processor: :cpu]]
    ]

    status = start_supervised!({Status, config: config([{:camera, camera}])})

    refute status in VisionCore.Outputs.subscribers(nil)
  end

  test "a snapshot of a unit with nothing running reports everything absent" do
    start_supervised!({Status, config: config([])})

    snapshot = Status.snapshot()

    assert snapshot.exporters == []

    assert snapshot.cameras == %{
             left: %{present: false, issues: []},
             right: %{present: false, issues: []}
           }

    for {_name, check} <- Map.merge(snapshot.pair, snapshot.depth),
        do: assert(check == %{level: :off, camera: nil, issues: []})

    assert snapshot.sync == %{present: false}
    assert snapshot.npu == nil
    assert snapshot.depth_hz == 0.0
  end

  test "reports each exporter's status, as the exporters list them" do
    start_exporter([])
    start_supervised!({Status, config: config([])})

    assert Status.snapshot().exporters == [%{id: "probe", name: "Probe", status: {:ok, "Linked"}}]
  end

  test "a listing that misses its deadline reports the exporters listed before as not answering" do
    start_exporter([])
    start_supervised!({Status, config: config([])})
    assert [%{id: "probe", status: {:ok, "Linked"}}] = Status.snapshot().exporters

    :ok = :sys.suspend(VisionCore.Exporters)
    snapshot = Status.snapshot()
    :ok = :sys.resume(VisionCore.Exporters)

    assert snapshot.exporters == [
             %{id: "probe", name: "Probe", status: {:warning, "Not answering"}}
           ]
  end

  describe "the sync" do
    alias VisionCore.Stereo.Pairer

    defp stereo_config, do: config([{:stereo, driver: Camera, left: [], right: []}])

    # One pair of frames measured by the stereo unit, the right one 0.2 ms after the left one.
    defp measure_one_pair do
      start_supervised!(
        {Pairer, cameras: [{Camera, "left"}, {Camera, "right"}], pipeline: self()}
      )

      for {label, capture_ns} <- [{"left", 1_000_000_000}, {"right", 1_000_200_000}] do
        frame = %Frame{label: label, width: 1, height: 1, capture_ns: capture_ns, grey: <<0>>}
        Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})
      end

      assert %{pairs: 1} = Pairer.sync()
    end

    defp run_camera(label) do
      camera = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(camera, Camera.name_for(label))
      on_exit(fn -> Process.exit(camera, :kill) end)
    end

    test "is the one the stereo unit measured while the cameras run" do
      measure_one_pair()
      for label <- ["left", "right"], do: run_camera(label)
      start_supervised!({Status, config: stereo_config()})

      assert %{present: true, pairs: 1} = Status.snapshot().sync
    end

    test "is absent while the cameras are not running, whatever was measured last" do
      measure_one_pair()
      start_supervised!({Status, config: stereo_config()})

      assert Status.snapshot().sync == %{present: false}
    end
  end

  test "a configured Hailo detector that is not running is reported as a failed Hailo-8" do
    start_supervised!({Status, config: config([{:hailo_detector, hef_path: "/missing.hef"}])})

    assert Status.snapshot().npu == %{
             kind: "Hailo-8",
             state: :failed,
             load_percent: nil,
             pipelines: %{detection: %{inference_ms: nil}}
           }
  end

  test "a configured QNN detector that is not running is reported as a failed Hexagon" do
    start_supervised!({Status, config: config([{:qnn_detector, dlc_path: "/missing.dlc"}])})

    assert Status.snapshot().npu == %{
             kind: "Hexagon",
             state: :failed,
             load_percent: nil,
             pipelines: %{detection: %{inference_ms: nil}}
           }
  end

  test "a QNN detector whose backend is available is reported as a running Hexagon" do
    available = spawn(&answer_backend/0)

    Process.register(
      available,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection)
    )

    on_exit(fn -> Process.exit(available, :kill) end)
    start_supervised!({Status, config: config([:qnn_detector])})

    assert Status.snapshot().npu == %{
             kind: "Hexagon",
             state: :running,
             load_percent: nil,
             pipelines: %{detection: %{inference_ms: nil}}
           }
  end

  # A backend in `state` that reports `times` as its inference times.
  defp answer_backend(times \\ nil, state \\ :running) do
    receive do
      {:"$gen_call", from, :state} -> GenServer.reply(from, state)
      {:"$gen_call", from, :inference_times} -> GenServer.reply(from, times)
    end

    answer_backend(times, state)
  end

  test "a Hexagon has failed while a backend has, and is starting while one opens its Port" do
    starting = spawn(fn -> answer_backend(nil, :starting) end)

    Process.register(
      starting,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection)
    )

    on_exit(fn -> Process.exit(starting, :kill) end)
    running = spawn(&answer_backend/0)

    Process.register(
      running,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :road)
    )

    on_exit(fn -> Process.exit(running, :kill) end)

    start_supervised!(
      {Status,
       config:
         config([:qnn_detector, {:qnn_detector, name: :road}, {:qnn_detector, name: :signs}])}
    )

    assert %{state: :failed} = Status.snapshot().npu

    signs = spawn(&answer_backend/0)
    Process.register(signs, VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :signs))
    on_exit(fn -> Process.exit(signs, :kill) end)

    assert %{state: :starting} = Status.snapshot().npu
  end

  defp register_backend(name, times) do
    backend = spawn(fn -> answer_backend(times) end)
    Process.register(backend, name)
    on_exit(fn -> Process.exit(backend, :kill) end)
  end

  defp next_load(timeout \\ 1_000) do
    assert_receive {:vision_status, %{npu: %{load_percent: load}} = snapshot}, timeout
    if is_nil(load), do: next_load(timeout), else: snapshot.npu
  end

  test "a QNN pipeline's inference times over a tick give the Hexagon's load and its mean time" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 100_000,
      count: 4
    })

    start_supervised!({Status, config: config([:qnn_detector]), tick_ms: 200})
    :ok = Status.subscribe()

    npu = next_load()

    assert npu.kind == "Hexagon"
    assert_in_delta npu.load_percent, 50.0, 25.0
    assert %{detection: %{inference_ms: 25.0}} = npu.pipelines
  end

  test "two QNN pipelines' times add up in the load, each keeping its own mean time" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 30_000,
      count: 3
    })

    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :road), %{
      sum_us: 40_000,
      count: 2
    })

    start_supervised!(
      {Status, config: config([:qnn_detector, {:qnn_detector, name: :road}]), tick_ms: 200}
    )

    :ok = Status.subscribe()

    npu = next_load()

    assert_in_delta npu.load_percent, 35.0, 5.0
    assert %{detection: %{inference_ms: 10.0}, road: %{inference_ms: 20.0}} = npu.pipelines
  end

  @road_segmenter {:qnn_segmenter, name: :road, source: {:camera, :hq}, dlc_path: "/missing.dlc"}

  test "a configured QNN segmenter that is not running is reported as a failed Hexagon" do
    start_supervised!({Status, config: config([@road_segmenter])})

    assert Status.snapshot().npu == %{
             kind: "Hexagon",
             state: :failed,
             load_percent: nil,
             pipelines: %{road: %{inference_ms: nil}}
           }
  end

  test "a QNN detector's and a QNN segmenter's times add up in the load, each keeping its own mean time" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 30_000,
      count: 3
    })

    register_backend(VisionCore.Pipelines.server(VisionCore.Segmentation.Backend.Qnn, :road), %{
      sum_us: 40_000,
      count: 2
    })

    start_supervised!({Status, config: config([:qnn_detector, @road_segmenter]), tick_ms: 200})
    :ok = Status.subscribe()

    npu = next_load()

    assert npu.state == :running
    assert_in_delta npu.load_percent, 35.0, 5.0
    assert %{detection: %{inference_ms: 10.0}, road: %{inference_ms: 20.0}} = npu.pipelines
  end

  test "a stub segmenter reports no NPU" do
    start_supervised!(
      {Status,
       config:
         config([
           {:segmenter,
            name: :road, backend: VisionCore.Segmentation.Backend.Stub, source: {:camera, :hq}}
         ])}
    )

    assert Status.snapshot().npu == nil
  end

  test "the load adds up only the pipelines on the reported accelerator's kind" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 30_000,
      count: 3
    })

    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Hailo, :road), %{
      sum_us: 80_000,
      count: 2
    })

    start_supervised!(
      {Status, config: config([:qnn_detector, {:hailo_detector, name: :road}]), tick_ms: 200}
    )

    :ok = Status.subscribe()
    npu = next_load()

    assert npu.kind == "Hexagon"
    assert_in_delta npu.load_percent, 15.0, 3.0
    assert %{detection: %{inference_ms: 10.0}, road: %{inference_ms: 40.0}} = npu.pipelines
  end

  test "the load is clamped to 100" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 900_000_000,
      count: 1
    })

    start_supervised!({Status, config: config([:qnn_detector]), tick_ms: 100})
    :ok = Status.subscribe()

    assert next_load().load_percent == 100.0
  end

  test "a window without an inference is a load of zero and no mean time" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 0,
      count: 0
    })

    start_supervised!({Status, config: config([:qnn_detector]), tick_ms: 100})
    :ok = Status.subscribe()

    assert %{load_percent: +0.0, pipelines: %{detection: %{inference_ms: nil}}} = next_load()
  end

  test "a backend that reports no times leaves the load and the mean time nil" do
    register_backend(
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection),
      nil
    )

    start_supervised!({Status, config: config([:qnn_detector]), tick_ms: 100})
    :ok = Status.subscribe()

    assert_receive {:vision_status, %{npu: %{state: :running}}}
    Process.sleep(250)

    assert %{load_percent: nil, pipelines: %{detection: %{inference_ms: nil}}} =
             Status.snapshot().npu
  end

  test "a snapshot asked between ticks does not take the backends' times" do
    register_backend(VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection), %{
      sum_us: 100_000,
      count: 4
    })

    start_supervised!({Status, config: config([:qnn_detector]), tick_ms: 60_000})

    assert %{load_percent: nil} = Status.snapshot().npu
  end

  test "the stub's pipeline has no load" do
    start_supervised!(
      {Status,
       config: config([{:detector, backend: VisionCore.Detection.Backend.Stub}]), tick_ms: 100}
    )

    :ok = Status.subscribe()
    assert_receive {:vision_status, %{npu: nil}}
  end

  test "a Hailo pipeline beside a stub one reports the Hailo-8" do
    available = spawn(&answer_backend/0)

    Process.register(
      available,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Hailo, :road)
    )

    on_exit(fn -> Process.exit(available, :kill) end)

    start_supervised!(
      {Status,
       config:
         config([
           {:detector, backend: VisionCore.Detection.Backend.Stub},
           {:hailo_detector, name: :road}
         ])}
    )

    assert Status.snapshot().npu == %{
             kind: "Hailo-8",
             state: :running,
             load_percent: nil,
             pipelines: %{road: %{inference_ms: nil}}
           }
  end

  test "two QNN pipelines report a running Hexagon while both backends are available, failed when one is not" do
    available = spawn(&answer_backend/0)

    Process.register(
      available,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :detection)
    )

    on_exit(fn -> Process.exit(available, :kill) end)
    two_pipelines = config([:qnn_detector, {:qnn_detector, name: :road}])
    start_supervised!({Status, config: two_pipelines})

    assert Status.snapshot().npu == %{
             kind: "Hexagon",
             state: :failed,
             load_percent: nil,
             pipelines: %{detection: %{inference_ms: nil}, road: %{inference_ms: nil}}
           }

    road = spawn(&answer_backend/0)
    Process.register(road, VisionCore.Pipelines.server(VisionCore.Detection.Backend.Qnn, :road))
    on_exit(fn -> Process.exit(road, :kill) end)

    assert Status.snapshot().npu == %{
             kind: "Hexagon",
             state: :running,
             load_percent: nil,
             pipelines: %{detection: %{inference_ms: nil}, road: %{inference_ms: nil}}
           }
  end

  test "a detector whose backend runs on no accelerator reports no NPU" do
    start_supervised!(
      {Status, config: config([{:detector, backend: VisionCore.Detection.Backend.Stub}])}
    )

    assert Status.snapshot().npu == nil
  end

  test "a detector that does not answer is reported failed without stalling the snapshot" do
    silent = spawn(fn -> Process.sleep(:infinity) end)

    Process.register(
      silent,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Hailo, :detection)
    )

    on_exit(fn -> Process.exit(silent, :kill) end)
    start_supervised!({Status, config: config([:hailo_detector])})

    {elapsed_us, snapshot} = :timer.tc(&Status.snapshot/0)

    assert %{state: :failed} = snapshot.npu
    assert elapsed_us < 1_000_000
  end

  test "callees that do not answer delay the snapshot by one timeout, not one each" do
    silent = spawn(fn -> Process.sleep(:infinity) end)

    Process.register(
      silent,
      VisionCore.Pipelines.server(VisionCore.Detection.Backend.Hailo, :detection)
    )

    on_exit(fn -> Process.exit(silent, :kill) end)
    start_exporter(delay_ms: 1_000)
    start_supervised!({Status, config: config([:hailo_detector])})

    {elapsed_us, snapshot} = :timer.tc(&Status.snapshot/0)

    assert %{npu: %{state: :failed}, exporters: [%{status: {:warning, "Not answering"}}]} =
             snapshot

    assert elapsed_us < 350_000
  end

  test "a new subscriber receives a snapshot at once" do
    start_supervised!({Status, config: config([]), tick_ms: 60_000})
    :ok = Status.subscribe()

    assert_receive {:vision_status, %{exporters: []}}, 500
  end

  test "an unsubscribed process receives no more snapshots" do
    start_supervised!({Status, config: config([]), tick_ms: 20})
    :ok = Status.subscribe()
    assert_receive {:vision_status, _snapshot}, 500

    :ok = Status.unsubscribe()
    Process.sleep(30)
    flush_snapshots()
    refute_receive {:vision_status, _snapshot}, 100
  end

  test "another process subscribes and unsubscribes a process by its pid" do
    start_supervised!({Status, config: config([]), tick_ms: 20})
    test = self()

    :ok = Task.await(Task.async(fn -> Status.subscribe(test) end))
    assert_receive {:vision_status, _snapshot}, 500

    :ok = Task.await(Task.async(fn -> Status.unsubscribe(test) end))
    Process.sleep(30)
    flush_snapshots()
    refute_receive {:vision_status, _snapshot}, 100
  end

  defp flush_snapshots do
    receive do
      {:vision_status, _snapshot} -> flush_snapshots()
    after
      0 -> :ok
    end
  end

  test "subscribers receive a snapshot every tick, with the depth rate" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()

    assert_receive {:vision_status, %{depth_hz: +0.0}}
    for _ <- 1..4, do: GenServer.cast(Status, {:stereo_pair, pair()})

    assert_receive {:vision_status, %{depth_hz: depth_hz}}, 500
    assert depth_hz > 0.0
  end

  test "counts the pairs and frames the stereo unit of its config publishes" do
    left = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(left, Camera.name_for("left"))
    on_exit(fn -> Process.exit(left, :kill) end)
    stereo = {:stereo, driver: Camera, left: [], right: []}
    start_supervised!({Status, config: config([stereo]), tick_ms: 200})
    :ok = Status.subscribe()

    for _ <- 1..4 do
      Outputs.publish({:stereo_pair, VisionCore.Stereo.Pipeline}, {:stereo_pair, pair()})

      Outputs.publish(
        {:camera_frame, Camera.name_for("left")},
        {:camera_frame, pair().left_frame}
      )
    end

    assert_receive {:vision_status, %{depth_hz: depth_hz, cameras: %{left: %{fps: fps}}}}
                   when depth_hz > 0.0 and fps > 0.0,
                   500
  end

  # A camera of its own: registered under its name, answering `live/1` with the figures of its capture.
  defmodule NamedCamera do
    use GenServer

    def name_for(label), do: Module.concat(__MODULE__, label)
    def live(server), do: GenServer.call(server, :live)

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name_for(name))

    @impl GenServer
    def init(_), do: {:ok, nil}

    @impl GenServer
    def handle_call(:live, _from, state),
      do:
        {:reply,
         %{
           exposure_time_us: 8_000,
           analogue_gain: 2.0,
           colour_temperature: 5_000,
           received_ms: 1
         }, state}
  end

  describe "a camera of its own" do
    defp hq_config, do: config([{:camera, name: :hq, driver: NamedCamera}])

    test "is absent while it is not running" do
      start_supervised!({Status, config: hq_config()})

      assert Status.snapshot().cameras.hq == %{present: false}
    end

    test "reports its rate over the tick and the figures its driver's live/1 gives" do
      start_supervised!(%{id: :hq, start: {NamedCamera, :start_link, ["hq"]}})
      start_supervised!({Status, config: hq_config(), tick_ms: 200})
      :ok = Status.subscribe()

      frame = %Frame{label: "hq", width: 2, height: 2, capture_ns: 0, jpeg: <<>>}

      for _ <- 1..4,
          do: Outputs.publish({:camera_frame, NamedCamera.name_for("hq")}, {:camera_frame, frame})

      assert_receive {:vision_status, %{cameras: %{hq: %{fps: fps} = hq}}} when fps > 0.0, 500

      assert hq == %{
               present: true,
               fps: fps,
               exposure_time_us: 8_000,
               analogue_gain: 2.0,
               colour_temperature: 5_000
             }
    end

    test "leaves the stereo sides' entries as they are" do
      start_supervised!({Status, config: hq_config()})

      assert %{left: %{present: false, issues: []}, right: %{present: false, issues: []}} =
               Status.snapshot().cameras
    end
  end

  test "each tick reports the row alignment averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{alignment: nil}}

    for offset <- [1.0, 2.0] do
      alignment = %{offset_rows: offset, band_offset_rows: [offset, offset, offset, offset]}
      GenServer.cast(Status, {:stereo_pair, %{pair() | alignment: alignment}})
    end

    assert_receive {:vision_status, %{alignment: %{offset_rows: 1.5, band_offset_rows: bands}}},
                   500

    assert bands == [1.5, 1.5, 1.5, 1.5]
  end

  test "answers the last tick's alignment without a snapshot" do
    start_supervised!({Status, config: config([]), tick_ms: 400})
    assert Status.alignment() == nil

    alignment = %{offset_rows: 0.4, band_offset_rows: [0.4, 0.4, 0.4, 0.4]}
    GenServer.cast(Status, {:stereo_pair, %{pair() | alignment: alignment}})
    Process.sleep(600)

    assert %{offset_rows: 0.4} = Status.alignment()
  end

  test "averages each band over the pairs that read it" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{alignment: nil}}

    for bands <- [[nil, 1.0, nil, 2.0], [3.0, 2.0, nil, 2.0]] do
      alignment = %{offset_rows: 1.0, band_offset_rows: bands}
      GenServer.cast(Status, {:stereo_pair, %{pair() | alignment: alignment}})
    end

    assert_receive {:vision_status, %{alignment: %{band_offset_rows: [3.0, 1.5, nil, 2.0]}}},
                   500
  end

  test "each tick reports the cameras' sharpness averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{sharpness: nil}}

    for right <- [0.02, 0.04] do
      GenServer.cast(Status, {:stereo_pair, %{pair() | sharpness: %{left: 0.04, right: right}}})
    end

    assert_receive {:vision_status, %{sharpness: %{left: left, right: right}}}, 500
    assert_in_delta left, 0.04, 1.0e-9
    assert_in_delta right, 0.03, 1.0e-9
  end

  test "each tick judges the brightness averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, _first}

    for right <- [110.0, 130.0] do
      GenServer.cast(Status, {:stereo_pair, %{pair() | brightness: %{left: 100.0, right: right}}})
    end

    # No camera runs, so the check is off, but the window's mean reaches it.
    assert_receive {:vision_status, %{pair: %{brightness: %{level: :off}}}}, 500
    assert %{brightness: %{left: 100.0, right: 120.0}} = :sys.get_state(Status)
  end

  test "each tick measures how near the last pair's depth reaches, then forgets the pair" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, _first}

    disparity = Nx.tensor([[120.0, 10.0]], type: :f32)

    GenServer.cast(
      Status,
      {:stereo_pair,
       %{
         pair()
         | disparity: disparity,
           disparity_scale: 1.0,
           disparity_range: %{min_disparity: 0, num_disparities: 128},
           geometry: %{focal_length_px: 896.0, baseline_m: 0.2}
       }}
    )

    assert_receive {:vision_status, _snapshot}, 500
    assert %{near: %{near_percent: 100.0}, last_pair: nil} = :sys.get_state(Status)
  end

  test "each tick reports the depth's quality averaged over its pairs" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, %{quality: nil}}

    for valid <- [60.0, 70.0] do
      metrics = [
        {:align_rows, 0.1, "rows"},
        {:matched_percent, valid, "%"},
        {:mean_disparity_px, 18.0, "px"},
        {:spread_px, 6.0, "px"},
        {:jitter_px, 0.3, "px"}
      ]

      GenServer.cast(Status, {:stereo_pair, %{pair() | metrics: metrics}})
    end

    assert_receive {:vision_status, %{quality: quality}} when quality != nil, 500

    assert quality == %{
             matched_percent: 65.0,
             mean_disparity_px: 18.0,
             spread_px: 6.0,
             jitter_px: 0.3
           }
  end

  test "each tick reports the CPU usage and the stereo segment time" do
    start_supervised!({Status, config: config([]), tick_ms: 200})
    :ok = Status.subscribe()
    assert_receive {:vision_status, _first}

    # Four pairs of 25 ms in a 200 ms window: half the time in the segment.
    for _ <- 1..4, do: GenServer.cast(Status, {:stereo_pair, %{pair() | device_ms: 25.0}})

    assert_receive {:vision_status, %{cpu_percent: cpu, stereo_segment_percent: segment}}, 500
    assert cpu >= 0.0 and cpu <= 100.0
    assert_in_delta segment, 50.0, 15.0
  end
end
