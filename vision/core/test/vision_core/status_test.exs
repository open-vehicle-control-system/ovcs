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

  test "a snapshot of a unit with nothing running reports everything absent" do
    start_supervised!({Status, config: config([])})

    snapshot = Status.snapshot()

    assert snapshot.exporters == []
    assert snapshot.cameras == %{left: %{present: false}, right: %{present: false}}
    assert snapshot.sync == %{present: false}
    assert snapshot.hailo == :absent
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

  test "a configured Hailo detector that is not running is reported failed" do
    start_supervised!({Status, config: config([{:hailo_detector, hef_path: "/missing.hef"}])})

    assert Status.snapshot().hailo == :failed
  end

  test "a detector that does not answer is reported failed without stalling the snapshot" do
    silent = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(silent, VisionCore.Detection.Backend.Hailo)
    on_exit(fn -> Process.exit(silent, :kill) end)
    start_supervised!({Status, config: config([:hailo_detector])})

    {elapsed_us, snapshot} = :timer.tc(&Status.snapshot/0)

    assert snapshot.hailo == :failed
    assert elapsed_us < 1_000_000
  end

  test "callees that do not answer delay the snapshot by one timeout, not one each" do
    silent = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(silent, VisionCore.Detection.Backend.Hailo)
    on_exit(fn -> Process.exit(silent, :kill) end)
    start_exporter(delay_ms: 1_000)
    start_supervised!({Status, config: config([:hailo_detector])})

    {elapsed_us, snapshot} = :timer.tc(&Status.snapshot/0)

    assert %{hailo: :failed, exporters: [%{status: {:warning, "Not answering"}}]} = snapshot
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
