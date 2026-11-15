defmodule VisionCore.Ros2.BagExporterTest do
  # Starts the Zenoh exporter's state, which subscribes to calibration keys.
  use ExUnit.Case, async: false

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias VisionCore.{BagTestUnit, Disks, McapReader, TestDisks}
  alias VisionCore.Exporter.Runner
  alias VisionCore.Parameters.{Group, Parameter}
  alias VisionCore.Ros2.Bag.Recording
  alias VisionCore.Ros2.BagExporter
  alias VisionCore.Ros2.BagExporter.Preset

  @moduletag :tmp_dir
  @moduletag :capture_log

  @replay_topics [
    "/hq/camera_info",
    "/hq/image_raw/compressed",
    "/stereo/left/camera_info",
    "/stereo/left/image_raw",
    "/stereo/right/camera_info",
    "/stereo/right/image_raw"
  ]

  # Holds each encode until the test answers it, as a codec that is slow would.
  defmodule HeldCodec do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl GenServer
    def init(test), do: {:ok, test}

    @impl GenServer
    def handle_call({:request, _request, _shared_frame}, from, test) do
      send(test, {:encoding, from})
      {:noreply, test}
    end
  end

  # Answers each encode at once.
  defmodule InstantCodec do
    use GenServer

    def start_link(_options), do: GenServer.start_link(__MODULE__, nil)

    @impl GenServer
    def init(nil), do: {:ok, nil}

    @impl GenServer
    def handle_call({:request, _request, _shared_frame}, _from, nil),
      do: {:reply, {:ok, <<0xFF, 0xD8, 0xFF, 0xD9>>}, nil}
  end

  @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"

  # The disks the exporter records on, under the name it reads them from by default.
  setup %{tmp_dir: tmp_dir} do
    disks =
      tmp_dir |> Path.join("system") |> TestDisks.setup!() |> TestDisks.start!(name: Disks)

    %{disks: disks}
  end

  defp recordings(%TestDisks{} = disks), do: disks.options[:internal]

  defp options(extra \\ []) do
    Keyword.merge(
      [
        config: BagTestUnit.config(),
        free_floor_bytes: 0,
        parameters: fn -> [parameter_group()] end,
        clock_synchronized?: fn -> true end
      ],
      extra
    )
  end

  defp parameter_group do
    %Group{
      id: "stereo.disparity",
      name: "Disparity",
      kind: :stage,
      pipeline: :stereo,
      status: {:ok, "Running"},
      parameters: [
        %Parameter{
          id: "stereo.disparity.paths",
          name: "Paths",
          type: :integer,
          applies: {:auto, "stereo.auto"},
          value: 3,
          default: 8,
          saved: 3,
          state: :saved
        }
      ]
    }
  end

  defp init!(options) do
    {:ok, state} = BagExporter.init(options)
    state
  end

  defp action(state, name, params) do
    {:reply, result, state} = BagExporter.handle_action(name, params, {self(), make_ref()}, state)
    {result, state}
  end

  defp start!(state, params) do
    {{:ok, started}, state} = action(state, :start, params)
    {started, state}
  end

  # Hands the exporter a value of each output it reads, captured `ago_ns` before now.
  defp hand(state, options, ago_ns \\ 0) do
    outputs = BagExporter.outputs(options)

    for {output, value} <- BagTestUnit.values(System.monotonic_time(:nanosecond) - ago_ns),
        output in outputs,
        reduce: state do
      state ->
        {:ok, state} = BagExporter.handle_output(output, value, state)
        state
    end
  end

  defp stop!(state) do
    {{:ok, stopped}, state} = action(state, :stop, %{})
    {stopped, state}
  end

  defp bag!(folder) do
    files = folder |> Path.join("*.mcap") |> Path.wildcard() |> Enum.sort()
    {Enum.map(files, &McapReader.read!(File.read!(&1))), metadata_yaml!(folder)}
  end

  defp metadata_yaml!(folder) do
    folder
    |> Path.join("metadata.yaml")
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("rosbag2_bagfile_information")
  end

  defp topics([file | _files]),
    do: file.channels |> Map.values() |> Enum.map(& &1.topic) |> Enum.sort()

  # Each message's topic, log time and header stamp in nanoseconds.
  defp stamped([file | _files]) do
    for message <- file.messages do
      <<0, 1, 0, 0, sec::little-signed-32, nanosec::little-32, _rest::binary>> = message.data
      {file.channels[message.channel_id].topic, message.log_time, sec * 1_000_000_000 + nanosec}
    end
  end

  test "is listed as ROS 2 · Bag, takes every value in a queue, and lists start and stop" do
    assert BagExporter.describe([]) == %{id: :ros2_bag, name: "ROS 2 · Bag"}
    assert BagExporter.delivery([]) == {:queue, 64}
    assert Enum.map(BagExporter.actions([]), & &1.name) == [:start, :stop]
    assert BagExporter.check(options()) == :ok
  end

  test "reads every output the presets record on the configuration" do
    assert BagExporter.outputs(options()) == [
             {:camera_frame, :left},
             {:camera_frame, :right},
             {:camera_frame, :hq, :view_jpeg},
             :stereo_pair,
             {:detections, :objects},
             {:segmentation, :road}
           ]

    assert BagExporter.outputs(options(config: %VisionCore.Config{})) == []
  end

  test "reads one output for a camera two presets name apart" do
    options = options(presets: [review: [cameras: [outputs: [hq: :small]]]])

    outputs = BagExporter.outputs(options)
    assert {:camera_frame, :hq, :view_jpeg} in outputs
    assert {:camera_frame, :hq, :small} in outputs

    config = options[:config]
    keys = Enum.map(outputs, &VisionCore.Exporter.output_key(&1, config))
    assert keys == Enum.uniq(keys)
  end

  test "builds nothing while idle", %{disks: disks} do
    options = options()
    state = options |> init!() |> hand(options)

    assert BagExporter.status(state) == {:ok, "Idle"}
    assert File.ls!(recordings(disks)) == []
  end

  test "replay records the preset's topics, stamped by the recording's clock, in a folder of its own",
       %{disks: disks} do
    options = options()
    state = init!(options)

    {started, state} = start!(state, %{"preset" => "replay", "clock" => "since_start"})
    assert %{preset: "replay", clock: "since_start", clock_in_use: "since_start"} = started
    assert Path.dirname(started.folder) == recordings(disks)
    assert Path.basename(started.folder) =~ ~r/^\d{8}T\d{6}Z_replay$/

    state = hand(state, options)
    {stopped, _state} = stop!(state)
    assert stopped.folder == started.folder

    assert stopped.bytes ==
             File.stat!(Path.join(started.folder, "#{Path.basename(started.folder)}_0.mcap")).size

    {[file] = files, metadata} = bag!(started.folder)
    assert topics(files) == @replay_topics

    for {topic, log_time, stamp} <- stamped(files) do
      assert stamp in 0..5_000_000_000, "#{topic} stamped #{stamp}"
      assert log_time in stamp..5_000_000_000
    end

    assert [%{name: "recording", metadata: recorded}] = file.metadata

    assert %{
             "preset" => "replay",
             "clock" => "since_start",
             "clock_in_use" => "since_start",
             "clock_synchronized" => "true"
           } = recorded

    assert metadata["custom_data"]["preset"] == "replay"
    assert metadata["message_count"] == length(file.messages)
  end

  test "the system clock stamps with the wall clock" do
    options = options()
    {started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    assert %{clock: "automatic", clock_in_use: "system", synchronized: true} = started

    {_stopped, _state} = state |> hand(options) |> stop!()

    now_ns = System.os_time(:nanosecond)
    {[file] = files, _metadata} = bag!(started.folder)

    for {_topic, log_time, stamp} <- stamped(files) do
      assert abs(now_ns - stamp) < 5_000_000_000
      assert abs(now_ns - log_time) < 5_000_000_000
    end

    first_log_time = file.messages |> Enum.map(& &1.log_time) |> Enum.min()

    for attachment <- file.attachments do
      assert attachment.log_time == attachment.create_time
      assert attachment.log_time in (now_ns - 5_000_000_000)..first_log_time
    end
  end

  test "an automatic clock not synchronized counts from the start" do
    options = options(clock_synchronized?: fn -> false end)
    {started, _state} = options |> init!() |> start!(%{"preset" => "review"})

    assert %{clock: "automatic", clock_in_use: "since_start", synchronized: false} = started
  end

  test "attaches the calibration files in use and the parameters, at the clock's start" do
    options = options()

    {started, state} =
      options |> init!() |> start!(%{"preset" => "replay", "clock" => "since_start"})

    stop!(state)

    {[file], _metadata} = bag!(started.folder)
    attachments = Map.new(file.attachments, &{&1.name, &1})
    assert Enum.all?(file.attachments, &(&1.log_time == 0 and &1.create_time == 0))

    assert Map.keys(attachments) == [
             "calibration/stereo_left.yaml",
             "calibration/stereo_right.yaml",
             "parameters.json"
           ]

    assert attachments["calibration/stereo_left.yaml"].media_type == "application/yaml"
    assert attachments["calibration/stereo_left.yaml"].data =~ "camera_matrix"

    assert [%{"id" => "stereo.disparity", "parameters" => [parameter]}] =
             Jason.decode!(attachments["parameters.json"].data)

    assert %{"id" => "stereo.disparity.paths", "value" => 3, "saved" => 3, "state" => "saved"} =
             parameter
  end

  test "review builds no raw image, and records the depth and the pipelines" do
    options = options()
    {started, state} = options |> init!() |> start!(%{"preset" => "review"})
    {_stopped, _state} = state |> hand(options) |> stop!()

    {files, _metadata} = bag!(started.folder)
    topics = topics(files)

    assert "/stereo/left/image_raw/compressed" in topics
    assert "/stereo/depth/image_rect" in topics
    assert Enum.any?(topics, &String.starts_with?(&1, "/objects/"))
    assert Enum.any?(topics, &String.starts_with?(&1, "/road/"))
    refute "/stereo/left/image_raw" in topics
    refute Enum.any?(topics, &String.starts_with?(&1, "/stereo/right/"))
    refute "/stereo/disparity" in topics
  end

  test "a vehicle's preset replaces the default one" do
    options = options(presets: [review: [cameras: [outputs: [hq: :view_jpeg]]]])
    assert BagExporter.check(options) == :ok

    {started, state} = options |> init!() |> start!(%{"preset" => "review"})
    {_stopped, _state} = state |> hand(options) |> stop!()

    {files, _metadata} = bag!(started.folder)
    assert topics(files) == ["/hq/camera_info", "/hq/image_raw/compressed"]
  end

  # Records 3 s of every output at 30 Hz of capture time: the stop's answer and messages by topic.
  defp record_30_hz(options, preset) do
    outputs = BagExporter.outputs(options)
    {started, state} = options |> init!() |> start!(%{"preset" => preset})
    first_ns = System.monotonic_time(:nanosecond) - 3_000_000_000

    state =
      for n <- 0..89,
          {output, value} <- BagTestUnit.values(first_ns + n * 33_333_333),
          output in outputs,
          reduce: state do
        state -> hand_over!(state, output, value)
      end

    {stopped, _state} = stop!(state)
    {files, _metadata} = bag!(started.folder)
    {stopped, files |> stamped() |> Enum.frequencies_by(&elem(&1, 0))}
  end

  # As the runner does: an output busy encoding takes its next value once the encode is answered.
  defp hand_over!(state, output, value) do
    case BagExporter.handle_output(output, value, state) do
      {:ok, state} ->
        state

      {:busy, state} ->
        assert_receive {reference, _answer} = answer when is_reference(reference)
        assert {:ready, ^output, state} = BagExporter.handle_info(answer, state)
        state
    end
  end

  test "review records the depth at 5 Hz and each camera at 10 Hz of capture time, none dropped" do
    options = options(recording: [queue: 10_000])
    {stopped, counts} = record_30_hz(options, "review")

    assert stopped.dropped == %{}
    assert counts["/stereo/depth/image_rect"] in 14..16
    assert counts["/stereo/depth/camera_info"] in 14..16
    assert counts["/hq/image_raw/compressed"] in 29..31
    # One camera info a second, as at 30 fps without a rate.
    assert counts["/hq/camera_info"] in 2..4
  end

  test "replay records every frame" do
    options = options(recording: [queue: 10_000])
    {stopped, counts} = record_30_hz(options, "replay")

    assert stopped.dropped == %{}
    assert counts["/stereo/left/image_raw"] == 90
    assert counts["/stereo/right/image_raw"] == 90
    assert counts["/hq/image_raw/compressed"] == 90
  end

  test "a camera that sends no JPEG is recorded on its capture times alone" do
    codec = start_supervised!(InstantCodec)

    options =
      options(
        config: BagTestUnit.config(grey_camera: true),
        jpeg_codec: codec,
        recording: [queue: 10_000]
      )

    {_stopped, counts} = record_30_hz(options, "replay")
    assert counts["/usb/image_raw/compressed"] == 90

    {_stopped, counts} = record_30_hz(options, "review")
    assert counts["/usb/image_raw/compressed"] in 29..31
  end

  test "a vehicle's preset sets its own rates, none without them" do
    preset = [cameras: [outputs: [hq: :view_jpeg]], max_hz: [cameras: 2]]
    options = options(presets: [review: preset], recording: [queue: 10_000])
    assert BagExporter.check(options) == :ok
    {_stopped, counts} = record_30_hz(options, "review")
    assert counts["/hq/image_raw/compressed"] in 5..7

    preset = [cameras: [outputs: [hq: :view_jpeg]]]
    options = options(presets: [review: preset], recording: [queue: 10_000])
    {_stopped, counts} = record_30_hz(options, "review")
    assert counts["/hq/image_raw/compressed"] == 90
  end

  test "refuses a preset's rate of a kind it does not know, or not above zero" do
    for max_hz <- [[videos: 1], [pairs: 0], [cameras: "10"], :fast] do
      options = options(presets: [review: [max_hz: max_hz]])
      assert {:error, reason} = BagExporter.check(options)
      assert reason =~ "review" and reason =~ "max_hz", inspect(max_hz)
    end
  end

  test "refuses a vehicle's preset it does not know, or one the Zenoh exporter refuses" do
    assert {:error, reason} = BagExporter.check(options(presets: [fast: []]))
    assert reason =~ "replay, review"

    assert {:error, reason} =
             BagExporter.check(options(presets: [review: [cameras: [names: [:usb]]]]))

    assert reason =~ "review" and reason =~ ":usb"
  end

  test "refuses a vehicle's preset that sets an option the bag exporter sets itself" do
    own_options = [
      config: %VisionCore.Config{},
      link: true,
      services: true,
      jpeg_codec: self(),
      publish: fn _topic, _module, _message, _options -> :ok end,
      stamp: fn _monotonic_ns -> nil end
    ]

    for {key, _value} = option <- own_options do
      options = options(presets: [replay: [option]])

      assert BagExporter.check(options) ==
               {:error, "its replay preset: sets #{key}:, which the bag exporter sets itself"}
    end

    options = options(presets: [review: Keyword.take(own_options, [:publish, :stamp])])

    assert BagExporter.check(options) ==
             {:error,
              "its review preset: sets publish:, stamp:, which the bag exporter sets itself"}
  end

  test "a vehicle's preset neither sends the recording's messages elsewhere nor stamps them" do
    test = self()

    preset =
      Preset.options(:replay, BagTestUnit.config()) ++
        [
          publish: fn topic, _module, _message, _options -> send(test, {:published, topic}) end,
          stamp: fn _monotonic_ns -> %Time{sec: 1_000_000, nanosec: 0} end
        ]

    options = options(presets: [replay: preset])

    {started, state} =
      options |> init!() |> start!(%{"preset" => "replay", "clock" => "since_start"})

    {_stopped, _state} = state |> hand(options) |> stop!()

    {files, _metadata} = bag!(started.folder)
    assert topics(files) == @replay_topics

    for {topic, _log_time, stamp} <- stamped(files),
        do: assert(stamp in 0..5_000_000_000, "#{topic} stamped #{stamp}")

    refute_received {:published, _topic}
  end

  test "refuses a free floor that is no count of bytes" do
    assert {:error, reason} = BagExporter.check(options(free_floor_bytes: -1))
    assert reason =~ "free_floor_bytes"
    assert {:error, _reason} = BagExporter.check(options(free_floor_bytes: "1 GB"))
  end

  test "refuses a root that is no folder's path, and an option it does not know" do
    assert BagExporter.check(options(root: "/tmp/recordings", id: :second_bag)) == :ok

    for root <- ["", 42, ~c"/tmp"] do
      assert {:error, reason} = BagExporter.check(options(root: root))
      assert reason =~ "root", inspect(root)
    end

    assert {:error, reason} = BagExporter.check(options(roots: "/tmp/recordings"))
    assert reason =~ ":roots"
  end

  test "refuses a chunk interval not below the time an eject waits for the recording" do
    assert BagExporter.check(options(recording: [chunk_interval_ms: 9_999])) == :ok

    for interval_ms <- [10_000, -1, "1 s"] do
      assert {:error, reason} =
               BagExporter.check(options(recording: [chunk_interval_ms: interval_ms]))

      assert reason =~ "chunk_interval_ms", inspect(interval_ms)
    end
  end

  test "refuses a start while recording, a stop while idle, and what it does not know" do
    state = init!(options())

    assert {{:error, {:refused, "Not recording"}}, state} = action(state, :stop, %{})

    assert {{:error, {:refused, reason}}, state} = action(state, :start, %{"preset" => "fast"})
    assert reason =~ "replay, review"

    assert {{:error, {:refused, reason}}, state} =
             action(state, :start, %{"preset" => "replay", "clock" => "gps"})

    assert reason =~ "system, since_start, automatic"

    {_started, state} = start!(state, %{"preset" => "replay"})
    assert {{:error, :busy}, state} = action(state, :start, %{"preset" => "review"})
    stop!(state)
  end

  test "starts review with the automatic clock when given no attributes" do
    {started, state} = options() |> init!() |> start!(%{})

    assert %{preset: "review", clock: "automatic"} = started
    assert Path.basename(started.folder) =~ ~r/_review$/
    stop!(state)

    assert [%{name: :start, description: description} | _stop] = BagExporter.actions([])
    assert description =~ "review by default"
  end

  test "a second recording in the same second takes a folder of its own" do
    state = init!(options())
    {first, state} = start!(state, %{"preset" => "replay"})
    {_stopped, state} = stop!(state)
    {second, state} = start!(state, %{"preset" => "replay"})
    stop!(state)

    refute first.folder == second.folder
    assert File.exists?(Path.join(first.folder, "metadata.yaml"))
  end

  test "status: what it records, since when, how much, and what it dropped" do
    options = options()
    {_started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    state = hand(state, options)

    # The recording counts a message once it has written it, after the cast.
    assert {:ok, text} = wait_for_status(state, &(&1 =~ "6 messages"))
    assert text =~ "Recording replay"
    assert text =~ "clock system, synchronized"
    assert text =~ "1 file"
    assert text =~ "on internal"
    assert text =~ ~r/\d+(\.\d+)? [kM]?B/
    stop!(state)

    options = options(recording: [queue: 0])
    {_started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    state = hand(state, options)

    assert {:warning, text} = BagExporter.status(state)
    assert text =~ "dropped"
    assert text =~ "/stereo/left/image_raw 1"
    stop!(state)
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(5) && eventually(check, attempts - 1)
    end
  end

  defp wait_for_status(state, done?, attempts \\ 50) do
    {_level, text} = status = BagExporter.status(state)

    if done?.(text) or attempts == 0 do
      status
    else
      Process.sleep(20)
      wait_for_status(state, done?, attempts - 1)
    end
  end

  test "is idle again once its recording ends on its own, saying why" do
    options = options(recording: [max_file_bytes: 1, chunk_interval_ms: 0])
    {started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    File.rm_rf!(started.folder)

    state = state |> hand(options) |> hand(options)
    state = check_until_stopped(state)

    assert {:warning, "Stopped: " <> reason} = BagExporter.status(state)
    assert reason =~ "open"
    assert {{:error, {:refused, "Not recording"}}, _state} = action(state, :stop, %{})
  end

  # Takes the exporter's checks until one finds the recording ended.
  defp check_until_stopped(state, attempts \\ 5) do
    assert_receive {BagExporter, :check, _pid} = check, 2_000
    {:ok, state} = BagExporter.handle_info(check, state)

    if state.recording && attempts > 0,
      do: check_until_stopped(state, attempts - 1),
      else: state
  end

  test "refuses to start on a folder the disk refuses", %{disks: disks} do
    File.rm_rf!(recordings(disks))
    File.write!(recordings(disks), "")
    state = init!(options())

    assert {{:error, {:failed, reason}}, state} = action(state, :start, %{"preset" => "replay"})
    assert reason =~ recordings(disks)
    assert BagExporter.status(state) == {:ok, "Idle"}
  end

  test "refuses to start with no disk to record on" do
    :ok = Disks.put_enabled(Disks, "internal", false)
    state = init!(options())

    assert {{:error, {:failed, reason}}, state} = action(state, :start, %{"preset" => "replay"})
    assert reason =~ "no disk"
    assert BagExporter.status(state) == {:ok, "Idle"}
  end

  test "records on the first disk, goes on on the next one, and sums the parts at the stop",
       %{disks: disks} do
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    :ok = Disks.put_order(Disks, [@stick, "internal"])
    {:ok, stick} = Disks.fetch(Disks, @stick)

    options = options(free_floor_bytes: 1_000_000, recording: [chunk_interval_ms: 1])
    {started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    assert Path.dirname(started.folder) == stick.recordings_path
    assert {:ok, text} = wait_for_status(state, &(&1 =~ "on #{@stick}"))

    TestDisks.put_free(disks, TestDisks.mount_point(disks, @stick), 0)
    assert {:ok, _text} = wait_for_status(state, &(&1 =~ "on internal"))
    state = hand(state, options)
    {stopped, _state} = stop!(state)

    second = Path.join(recordings(disks), Path.basename(started.folder) <> "_part2")
    assert stopped.folders == [started.folder, second]

    assert stopped.bytes ==
             [started.folder, second]
             |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.mcap")))
             |> Enum.map(&File.stat!(&1).size)
             |> Enum.sum()

    assert {[_file], %{"message_count" => 6}} = bag!(second)
    assert text =~ "Recording replay"
  end

  test "starts the disks it records on as its helper, the unit's storage in its root" do
    assert BagExporter.children([]) == [
             {Disks, name: Disks, internal: "/data/recordings", eject_timeout_ms: 10_000}
           ]

    assert [{Disks, options}] = BagExporter.children(root: "/tmp/recordings", disks: :other)
    assert options[:name] == :other
    assert options[:internal] == "/tmp/recordings"
  end

  test "records in its root on a host", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "host_recordings")
    name = :"bag_exporter_test_disks_#{System.unique_integer([:positive])}"
    options = options(root: root, disks: name)
    [{Disks, disks_options}] = BagExporter.children(options)
    start_supervised!({Disks, disks_options ++ [repo: TestDisks.start_repo!()]})

    eventually(fn ->
      match?({:ok, %{free_bytes: free}} when free != nil, Disks.fetch(name, "internal"))
    end)

    {started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    {_stopped, _state} = stop!(state)

    assert Path.dirname(started.folder) == root
    assert File.exists?(Path.join(started.folder, "metadata.yaml"))
  end

  test "terminate/2 closes the recording" do
    options = options()
    {started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    state = hand(state, options)

    BagExporter.terminate(:shutdown, state)

    {[file], metadata} = bag!(started.folder)
    assert length(file.messages) == 6
    assert metadata["message_count"] == 6
  end

  test "a runner that is killed leaves its recording closed" do
    options = options()

    runner =
      start_supervised!(
        {Runner, exporter: BagExporter, options: options, config: options[:config]},
        restart: :temporary
      )

    :sys.get_state(runner)
    assert {:ok, started} = Runner.action(runner, "start", %{"preset" => "replay"}, 5_000)
    recording = :sys.get_state(runner).exporter_state.recording.pid
    monitor = Process.monitor(recording)

    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^recording, :killed}, 5_000

    assert {[%{messages: []}], %{"files" => [_file]}} = bag!(started.folder)
    assert Recording.status(recording) == nil
  end

  test "a start whose builder raises answers the failure and leaves its recording closed",
       %{tmp_dir: tmp_dir, disks: disks} do
    # The builder's init computes the camera's transform, whose numbers overflow.
    pose = Path.join(tmp_dir, "hq_pose.yaml")
    File.write!(pose, "rotation: [1.0e+308, 0, 0, 0, 1.0e+308, 0, 0, 0, 1.0e+308]\n")
    File.write!(pose, "translation: [0, 0, 0]\n", [:append])
    options = options(config: BagTestUnit.config(pose: pose))
    assert BagExporter.check(options) == :ok

    runner =
      start_supervised!(
        {Runner, exporter: BagExporter, options: options, config: options[:config]}
      )

    assert {:error, {:failed, reason}} =
             Runner.action(runner, "start", %{"preset" => "replay"}, 5_000)

    assert reason =~ "cannot build the replay preset's messages: ** (ArithmeticError)"
    assert [folder] = disks |> recordings() |> Path.join("*") |> Path.wildcard()
    assert {[%{messages: []}], %{"files" => [_file]}} = bag!(folder)
  end

  test "makes a busy output ready when its encode answers after the stop" do
    codec = start_supervised!({HeldCodec, self()})
    options = options(jpeg_codec: codec)
    {_started, state} = options |> init!() |> start!(%{"preset" => "review"})

    grey = %{BagTestUnit.stereo_frame(:left, System.monotonic_time(:nanosecond)) | jpeg: nil}
    assert {:busy, state} = BagExporter.handle_output({:camera_frame, :left}, grey, state)
    assert_receive {:encoding, encode}

    {_stopped, state} = stop!(state)
    GenServer.reply(encode, {:ok, "the jpeg"})

    assert_receive {reference, _answer} = answer when is_reference(reference)
    assert {:ready, {:camera_frame, :left}, _state} = BagExporter.handle_info(answer, state)
  end

  test "keeps one loop of transforms when a recording starts again within a second",
       %{tmp_dir: tmp_dir} do
    pose = Path.join(tmp_dir, "hq_pose.yaml")
    File.write!(pose, "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [-0.1, 0, 0]\n")
    options = options(config: BagTestUnit.config(pose: pose))

    {_started, state} = options |> init!() |> start!(%{"preset" => "replay"})
    {_stopped, state} = stop!(state)
    {_started, state} = start!(state, %{"preset" => "replay"})

    # Both recordings' first ticks.
    assert_receive :publish_transforms
    {:ok, state} = BagExporter.handle_info(:publish_transforms, state)
    assert_receive :publish_transforms
    {:ok, state} = BagExporter.handle_info(:publish_transforms, state)

    assert_receive :publish_transforms, 1_500
    {:ok, state} = BagExporter.handle_info(:publish_transforms, state)
    refute_receive :publish_transforms, 900
    stop!(state)
  end
end
