defmodule VisionCore.Debug.ExporterTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Debug.Exporter
  alias VisionCore.Exporter.Runner
  alias VisionCore.Outputs
  alias VisionCore.Parameters.MemoryStore
  alias VisionCore.Stereo.Pair

  @moduletag :capture_log
  @pairs {:stereo_pair, VisionCore.Stereo.Pipeline}
  @detections {:detections, VisionCore.Detection.Pipeline}
  @options [burst_pairs: 3, burst_ms: 50, settle_ms: 100, deadline_ms: 2_000]
  @calibration Path.expand("../../support/calibration", __DIR__)
  @width 8
  @height 6

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp stereo,
    do:
      {:stereo,
       driver: Camera,
       left: [calibration_path: Path.join(@calibration, "stereo_left.yaml")],
       right: [calibration_path: Path.join(@calibration, "stereo_right.yaml")]}

  defp config(components \\ [stereo()]), do: %VisionCore.Config{components: components}

  # A runner of the exporter with the test's options, telling the test when it subscribes to the
  # status and unsubscribes, each with the monotonic time.
  defp start_runner(options, config \\ config()) do
    test = self()

    status =
      {fn _runner -> send(test, {:burst_started, now_ms()}) end,
       fn _runner -> send(test, {:burst_ended, now_ms()}) end}

    options = Keyword.merge(@options ++ [config: config, status: status], options)

    runner =
      start_supervised!({Runner, exporter: Exporter, options: options, config: config})

    :sys.get_state(runner)
    runner
  end

  # With no change recorded and the unit's state given.
  defp start_debug(options \\ [], config \\ config()),
    do:
      start_runner(
        Keyword.merge([last_change: fn -> nil end, unit_state: &unit_state/0], options),
        config
      )

  defp unit_state do
    %{
      firmware: nil,
      parameters: [],
      configuration: %{"components" => []},
      calibration: %{left: "left calibration\n", right: "right calibration\n"},
      hostname: "unit-1"
    }
  end

  defp export(runner), do: Task.async(fn -> Runner.action(runner, "export", %{}, 5_000) end)

  # Returns once the runner has handled the pair: it hands its exporter only the newest one waiting.
  defp publish_pair(runner, pair) do
    Outputs.publish(@pairs, {:stereo_pair, pair})
    :sys.get_state(runner)
  end

  defp publish_pairs(runner, indexes), do: Enum.each(indexes, &publish_pair(runner, pair(&1)))

  defp pair(index, fields \\ []) do
    image = Nx.iota({@height, @width}, type: :u8)

    struct!(
      %Pair{
        left_frame: frame("left", index),
        right_frame: frame("right", index),
        left: image,
        right: image,
        disparity_bytes: :binary.copy(<<4.0::float-32-little>>, @width * @height),
        depth: :binary.copy(<<1_500::16-little>>, @width * @height),
        sharpness: %{left: 100.0, right: 90.0},
        alignment: %{offset_rows: 0.1, band_offset_rows: [0.1]},
        metrics: [{:matched_percent, 90.0, "%"}],
        device_ms: 20.0,
        stage_ms: %{total: 30.0}
      },
      fields
    )
  end

  defp frame(label, capture_ns),
    do: %Frame{
      label: label,
      width: @width,
      height: @height,
      capture_ns: capture_ns,
      grey: :binary.copy(<<rem(capture_ns, 256)>>, @width * @height)
    }

  defp files(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])

    Map.new(entries, fn {name, content} ->
      [_directory, path] = name |> List.to_string() |> String.split("/", parts: 2)
      {path, content}
    end)
  end

  defp json(files, name), do: Jason.decode!(Map.fetch!(files, name))

  defp recording(runner), do: :sys.get_state(runner).exporter_state.recording

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "answers a zip once the burst has its pairs and its duration" do
    runner = start_debug(frames_kept: 2)
    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    started_ms = recording(runner).started_ms
    assert Runner.status(runner) == {:ok, "Exporting"}

    publish_pairs(runner, 1..2)
    eventually(fn -> recording(runner).duration_reached end)
    refute Task.yield(task, 0)
    publish_pair(runner, pair(3))

    assert {:file, filename, "application/zip", zip} = Task.await(task)
    assert_receive {:burst_ended, ended_ms}
    assert ended_ms - started_ms >= 50
    assert filename =~ ~r/^vision-export-unit-1-\d{8}T\d{6}Z\.zip$/

    files = files(zip)
    manifest = json(files, "manifest.json")
    assert manifest["burstPairs"] == 3
    assert manifest["framesKept"] == 2
    assert manifest["statusAvailable"] == true
    assert manifest["changeAgeMs"] == nil
    assert manifest["changesDuringBurst"] == 0
    assert [1, 2, 3] = Enum.map(json(files, "figures.json")["pairs"], & &1["captureNs"])
    assert Map.has_key?(files, "frames/001-left.png")
    refute Map.has_key?(files, "frames/002-left.png")
    assert files["calibration/left.yaml"] == "left calibration\n"
    refute Map.has_key?(files, "detections.json")
    refute Map.has_key?(files, "last/depth-coloured.jpg")
    eventually(fn -> Runner.status(runner) == {:ok, "Ready"} end)
  end

  test "waits for the settle time after a change" do
    changed_ms = now_ms()
    runner = start_debug(last_change: fn -> changed_ms end)
    task = export(runner)

    {next_index, published_ms} = publish_until_burst(runner)
    publish_pairs(runner, next_index..(next_index + 2))

    assert {:file, _filename, "application/zip", zip} = Task.await(task)
    files = files(zip)
    assert json(files, "manifest.json")["changeAgeMs"] >= 100

    for %{"captureNs" => index} <- json(files, "figures.json")["pairs"],
        Map.has_key?(published_ms, index),
        do: assert(published_ms[index] >= changed_ms + 100)
  end

  # Publishes a pair every few milliseconds, its capture time its index, until the burst starts;
  # returns the next index and when each pair had been published.
  defp publish_until_burst(runner, index \\ 0, published_ms \\ %{}) do
    receive do
      {:burst_started, _at_ms} -> {index, published_ms}
    after
      5 ->
        if index == 400, do: flunk("the burst did not start")
        publish_pair(runner, pair(index))
        publish_until_burst(runner, index + 1, Map.put(published_ms, index, now_ms()))
    end
  end

  test "refuses a second export while one runs" do
    runner = start_debug()
    task = export(runner)
    assert_receive {:burst_started, _at_ms}

    assert Runner.action(runner, "export", %{}, 1_000) == {:error, :busy}

    publish_pairs(runner, 1..3)
    assert {:file, _filename, "application/zip", _zip} = Task.await(task)
  end

  test "answers a timeout naming the pairs that came, and is ready again" do
    runner = start_debug(deadline_ms: 1_000)
    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    publish_pair(runner, pair(1))

    assert {:error, {:timeout, message}} = Task.await(task)
    assert message =~ "1 of 3 pairs"
    assert_receive {:burst_ended, _at_ms}
    assert Runner.status(runner) == {:ok, "Ready"}

    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    publish_pairs(runner, 1..3)
    assert {:file, _filename, "application/zip", _zip} = Task.await(task)
  end

  test "answers a timeout while the unit keeps changing" do
    runner = start_debug(last_change: &now_ms/0, deadline_ms: 1_000)

    assert {:error, {:timeout, message}} = Runner.action(runner, "export", %{}, 5_000)
    assert message =~ "0 of 3 pairs"
    refute_received {:burst_started, _at_ms}
    assert Runner.status(runner) == {:ok, "Ready"}
  end

  test "returns to Ready when the caller is gone before the answer" do
    runner = start_debug()
    caller = spawn(fn -> Runner.action(runner, "export", %{}, 5_000) end)
    assert_receive {:burst_started, _at_ms}

    Process.exit(caller, :kill)
    publish_pairs(runner, 1..3)

    assert_receive {:burst_ended, _at_ms}
    eventually(fn -> Runner.status(runner) == {:ok, "Ready"} end)
  end

  test "records a change during the burst" do
    {:ok, changes} = Agent.start_link(fn -> nil end)
    runner = start_debug(last_change: fn -> Agent.get(changes, & &1) end)
    task = export(runner)
    assert_receive {:burst_started, _at_ms}

    publish_pair(runner, pair(1))
    Agent.update(changes, fn _never -> now_ms() end)
    publish_pairs(runner, 2..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    assert json(files(zip), "manifest.json")["changesDuringBurst"] == 1
  end

  test "keeps only the status snapshots that arrive a snapshot's window after the burst starts" do
    test = self()

    subscribe = fn runner ->
      send(runner, {:vision_status, snapshot(1.0)})
      send(test, :subscribed)
    end

    runner = start_debug(status: {subscribe, fn _runner -> :ok end}, snapshot_delay_ms: 300)
    task = export(runner)
    assert_receive :subscribed
    started_ms = recording(runner).started_ms

    send(runner, {:vision_status, snapshot(2.0)})
    Process.sleep(max(started_ms + 300 - now_ms(), 0))
    send(runner, {:vision_status, snapshot(3.0)})
    publish_pairs(runner, 1..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    files = files(zip)
    assert json(files, "manifest.json")["statusAvailable"] == true
    assert json(files, "manifest.json")["statusSnapshots"] == 1
    assert [3.0] = Enum.map(json(files, "figures.json")["snapshots"], & &1["depthHz"])
  end

  defp snapshot(depth_hz),
    do: %{
      cameras: %{left: %{present: true}, right: %{present: true}},
      sync: %{present: true},
      depth_hz: depth_hz,
      cpu_percent: 20.0,
      stereo_segment_percent: 50.0
    }

  test "exports without status snapshots when Status is not running, and says so" do
    test = self()

    subscribe = fn runner ->
      send(test, :subscribing)
      exit({:noproc, {GenServer, :call, [VisionCore.Status, {:subscribe, runner}, 5_000]}})
    end

    runner = start_debug(status: {subscribe, fn _runner -> :ok end})
    task = export(runner)
    assert_receive :subscribing
    publish_pairs(runner, 1..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    manifest = json(files(zip), "manifest.json")
    assert manifest["statusAvailable"] == false
    assert manifest["statusSnapshots"] == 0
  end

  test "answers its status during a burst while Status runs, which asks it for its status" do
    test = self()

    # Holds the subscription until the test lets it go.
    subscribe = fn runner ->
      send(test, {:subscribing, self()})
      receive do: (:subscribe -> VisionCore.Status.subscribe(runner))
    end

    options =
      @options ++
        [
          last_change: fn -> nil end,
          unit_state: &unit_state/0,
          status: {subscribe, &VisionCore.Status.unsubscribe/1}
        ]

    start_supervised!({VisionCore.Exporters, config: config(), exporters: [{Exporter, options}]})
    start_supervised!({VisionCore.Status, config: config(), tick_ms: 50})
    runner = runner_of_debug()

    task = Task.async(fn -> VisionCore.Exporters.action("debug", "export", %{}, 5_000) end)
    assert_receive {:subscribing, subscriber}
    assert Runner.status(runner) == {:ok, "Exporting"}

    send(subscriber, :subscribe)
    eventually(fn -> status_subscriber?(runner) end)
    assert Runner.status(runner) == {:ok, "Exporting"}
    publish_pairs(runner, 1..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    assert json(files(zip), "manifest.json")["statusAvailable"] == true
    eventually(fn -> not status_subscriber?(runner) end)
  end

  defp status_subscriber?(pid),
    do: Map.has_key?(:sys.get_state(VisionCore.Status).subscribers, pid)

  test "includes the detections published during the burst" do
    runner = start_debug([], config([stereo(), :detector]))

    detection = %{
      label: "cup",
      score: 0.9,
      z: 1.5,
      class_id: 41,
      box: %{x0: 1, y0: 1, x1: 3, y1: 4},
      outline: [{2.0, 3.0}, {4.0, 6.0}]
    }

    Outputs.publish(@detections, {:detections, pair(0), [%{detection | label: "before"}]})
    :sys.get_state(runner)

    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    publish_pair(runner, pair(1))

    Outputs.publish(@detections, {:detections, pair(1), [detection]})
    publish_pairs(runner, 2..3)

    assert {:file, _filename, _type, zip} = Task.await(task)

    assert json(files(zip), "detections.json") == [
             %{
               "captureNs" => 1,
               "detections" => [
                 %{
                   "label" => "cup",
                   "score" => 0.9,
                   "distanceM" => 1.5,
                   "outline" => [[0.25, 0.5], [0.5, 1.0]]
                 }
               ]
             }
           ]
  end

  test "reads the pairs, and the detections when the configuration has a detector" do
    assert Exporter.outputs(config: config()) == [:stereo_pair]
    assert Exporter.outputs(config: config([stereo(), :detector])) == [:stereo_pair, :detections]
  end

  test "does nothing with pairs between exports" do
    runner = start_debug()

    publish_pairs(runner, 1..3)

    assert recording(runner) == nil
    assert Runner.status(runner) == {:ok, "Ready"}
  end

  test "answers why it failed when the last pair lacks what the export needs, and is ready again" do
    runner = start_debug()
    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    for index <- 1..3, do: publish_pair(runner, pair(index, depth: nil))

    assert {:error, {:failed, message}} = Task.await(task)
    assert message =~ ":depth"
    eventually(fn -> Runner.status(runner) == {:ok, "Ready"} end)
  end

  test "collects the unit's state from the unit itself by default" do
    start_supervised!({VisionCore.Parameters, store: MemoryStore})
    runner = start_runner([])
    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    publish_pairs(runner, 1..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    files = files(zip)
    {:ok, hostname} = :inet.gethostname()
    manifest = json(files, "manifest.json")
    assert manifest["hostname"] == List.to_string(hostname)
    assert Map.has_key?(manifest["firmware"], "revision")
    assert manifest["changeAgeMs"] == nil
    assert json(files, "parameters.json") == []
    assert json(files, "configuration.json") == VisionCore.settings()

    assert files["calibration/left.yaml"] ==
             File.read!(Path.join(@calibration, "stereo_left.yaml"))

    assert files["calibration/right.yaml"] ==
             File.read!(Path.join(@calibration, "stereo_right.yaml"))
  end

  @tag :jpeg
  test "includes the depth as the dashboard colours it, encoded on its JPEG codec" do
    start_supervised!({VisionCore.Jpeg, name: :debug_test_codec})
    runner = start_debug(jpeg_codec: :debug_test_codec)
    task = export(runner)
    assert_receive {:burst_started, _at_ms}
    publish_pairs(runner, 1..3)

    assert {:file, _filename, _type, zip} = Task.await(task)
    assert <<0xFF, 0xD8, _rest::binary>> = files(zip)["last/depth-coloured.jpg"]
  end

  test "runs under VisionCore.Exporters, listed with its action, and answers it" do
    test = self()

    options =
      @options ++
        [
          last_change: fn -> nil end,
          unit_state: &unit_state/0,
          status:
            {fn _runner -> send(test, {:burst_started, now_ms()}) end, fn _runner -> :ok end}
        ]

    start_supervised!({VisionCore.Exporters, config: config(), exporters: [{Exporter, options}]})

    assert [
             %{
               id: "debug",
               name: "Debug",
               status: {:ok, "Ready"},
               outputs: [%{output: :stereo_pair}],
               actions: [%{name: :export}]
             }
           ] = VisionCore.Exporters.list()

    task = Task.async(fn -> VisionCore.Exporters.action("debug", "export", %{}, 5_000) end)
    assert_receive {:burst_started, _at_ms}
    publish_pairs(runner_of_debug(), 1..3)

    assert {:file, _filename, "application/zip", _zip} = Task.await(task)
  end

  defp runner_of_debug do
    {:debug, supervisor, :supervisor, _modules} =
      VisionCore.Exporters |> Supervisor.which_children() |> List.keyfind(:debug, 0)

    {Runner, runner, :worker, _modules} =
      supervisor |> Supervisor.which_children() |> List.keyfind(Runner, 0)

    runner
  end

  test "check/1 refuses a configuration without a stereo unit" do
    assert Exporter.check(config: config([])) == {:error, "no stereo unit to export"}
    assert Exporter.check(config: config()) == :ok
  end

  test "is listed as Debug, with its export action" do
    assert Exporter.describe([]) == %{id: :debug, name: "Debug"}

    assert Exporter.actions([]) == [
             %{
               name: :export,
               label: "Export",
               description: "A burst of pairs and the unit's state, as a zip"
             }
           ]
  end
end
