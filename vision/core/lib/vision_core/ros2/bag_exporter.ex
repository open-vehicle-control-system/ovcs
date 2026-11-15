defmodule VisionCore.Ros2.BagExporter do
  @moduledoc """
  Records the vision unit's ROS 2 messages into rosbag2 folders: a
  `VisionCore.Exporter`, listed as `ros2_bag`, "ROS 2 · Bag", which
  `VisionCore.Exporters` runs as any other.

  A recording starts with `start_recording/3` and stops with
  `stop_recording/2`, which reach the exporter through its runner
  (`VisionCore.Exporter.Runner.call/3`); `VisionCore.Recordings` calls
  them. Its messages are those `VisionCore.Ros2.ZenohExporter` would publish with
  the options of its preset (`VisionCore.Ros2.BagExporter.Preset`), built
  by a `ZenohExporter` state this exporter holds while it records, whose
  `:publish` writes to a `VisionCore.Ros2.Bag.Recording`. It needs no
  ROS 2 link and answers no service. While idle it builds nothing.

  A recording records into `<YYYYMMDDTHHMMSSZ>_<preset>`, the time the
  UTC start, `_2`, `_3`… after it for a name a recording on any mounted
  disk has, a part `<name>_part<n>` included, so that no two recordings
  join, in the recordings folder of the first disk
  `VisionCore.Disks.next/3` gives.
  A recording goes on on the next disk when its disk fills past
  `:free_floor_bytes`, is ejected or pulled out, in a folder of the same
  name with `_part<n>` (`VisionCore.Ros2.Bag.Recording`).

  The clock stamps every header and transform, and each message's log
  time, the time the message is handed to the recording. The first MCAP
  file attaches, at the clock's start, the calibration files in use
  (`VisionCore.Calibration`), as `calibration/<file>`, and the parameters
  (`VisionCore.Parameters.groups/0`) as `parameters.json`, and carries as
  its metadata, as `metadata.yaml` does: the preset, the clock chosen, the
  clock in use and whether it was synchronized, the start, the vehicle and
  the firmware (`OvcsVehicle.FirmwareInfo`).

  ## Outputs, rates and drops

  `outputs/1` reads what any preset records on the configuration, fixed
  at start: one output per `VisionCore.Outputs` key, so a camera two
  presets take under two names is read once. While recording, only the
  outputs of the recording's preset are handed to its `ZenohExporter`
  state, each at most as often a second as the preset's `:max_hz` gives
  its kind (`VisionCore.Ros2.BagExporter.Preset.max_hz/1`). The rate is
  measured on capture times, in slots `1 / max_hz` s apart, so that 5 Hz
  of 30 fps takes every 6th value; a value before its output's next slot
  is skipped, which is no drop. Replay records every value. Review
  records the pairs, their depth and its camera info, at 5 Hz, each
  camera's image at 10 Hz with its camera info every 10th image, and the
  stereo left image, encoded from grey frames, at most 10 a second, the
  stereo `:raw_image_max_hz` of the `ZenohExporter`.

  Every value is queued (`delivery/1`, 64 per output): the runner's
  drops are counted by output beside the status, the recording's by
  topic in it and in `metadata.yaml`.

  ## Status and ends

  `status/1` is `Idle`, or the recording's preset, start, duration,
  disk, clock, bytes, files, messages and drops by topic, a warning once
  any message is dropped. A recording that ends with no disk left is
  seen within a second: the exporter is idle again and its status a
  warning saying why until the next start. `terminate/2` closes a
  recording; the recording process is linked to the runner, whose exit
  closes it as well.

  Its helper (`c:VisionCore.Exporter.children/1`) is the
  `VisionCore.Disks` it records on, so a unit without a bag exporter
  mounts no disk.

  ## Options

    * `:presets` (`[]`) — a vehicle's `ZenohExporter` options replacing a
      preset's, by preset name, with its own `:max_hz`, every value
      without: `[review: [cameras: [names: [:front]], max_hz: [cameras: 5]]]`.
      `check/1` refuses a name that is no preset, a `:max_hz` that
      `VisionCore.Ros2.BagExporter.Preset.max_hz/1` refuses, options
      the `ZenohExporter` refuses, and the options this exporter sets
      itself: `:config`, `:link`, `:services`, `:jpeg_codec`, `:publish`
      and `:stamp`.
    * `:disks` (`[]`) — the options of the `VisionCore.Disks` it starts
      and records on, but `internal:`, which `:root` sets; registered as
      `VisionCore.Disks` unless they give a `:name`. The vision API reads
      the disks of that name. `check/1` refuses one that is no keyword
      list or sets `internal:`.
    * `:root` (`"/data/recordings"`) — the recordings folder of the
      unit's own storage, the disk `internal`; another folder on a host.
      `check/1` refuses one that is no path.
    * `:free_floor_bytes` (`1_000_000_000`) — the free bytes a disk keeps:
      a recording starts on a disk above it and leaves one below it.
      `check/1` refuses one that is no count of bytes.
    * `:recording` (`[]`) — the `VisionCore.Ros2.Bag.Recording` options
      `:compression`, `:max_file_bytes`, `:buffer_bytes` and
      `:chunk_interval_ms`. `check/1` refuses a `:chunk_interval_ms` not
      below the time an eject waits for the recording to leave the disk,
      which it checks once a chunk interval: 10 s, or the
      `:eject_timeout_ms` of `:disks`.
    * `:parameters` (`&VisionCore.Parameters.groups/0`) — the parameter
      groups to attach, none when it exits.
    * `:clock_synchronized?` — whether the clock is synchronized, the
      `:synchronized?` of `VisionCore.Ros2.Bag.Clock.new/3`.
    * `:jpeg_codec` (`VisionCore.Jpeg`) and `:config` (the active
      `VisionCore.Config`), which `VisionCore.Exporters` gives.

  `check/1` refuses any other option but the exporter's `:id`.
  """
  @behaviour VisionCore.Exporter

  require Logger

  alias OvcsVehicle.FirmwareInfo
  alias VisionCore.Camera.Frame
  alias VisionCore.{Disks, Exporter}
  alias VisionCore.Exporter.Runner
  alias VisionCore.Parameters.Group
  alias VisionCore.Ros2.Bag.{Clock, Recording}
  alias VisionCore.Ros2.BagExporter.Preset
  alias VisionCore.Ros2.ZenohExporter
  alias VisionCore.Stereo.Pair

  @free_floor_bytes 1_000_000_000
  @root "/data/recordings"
  # A recording leaves an ejecting disk at its next check, a chunk interval later at most.
  @eject_timeout_ms 10_000
  @known_options [
    :id,
    :presets,
    :disks,
    :root,
    :free_floor_bytes,
    :recording,
    :parameters,
    :clock_synchronized?,
    :jpeg_codec,
    :config
  ]
  @queue 64
  @check_interval_ms 1_000
  @clocks [:system, :since_start, :automatic]
  # A start waits for the disk to take the folder and the first file.
  @start_timeout_ms 15_000
  # A stop waits for the recording to write what it holds, longer than `Bag.Recording.stop/1` waits.
  @stop_timeout_ms 45_000
  @recording_timeout_ms 5_000
  @recording_options [:compression, :max_file_bytes, :buffer_bytes, :chunk_interval_ms]
  @own_zenoh_options [:config, :link, :services, :jpeg_codec, :publish, :stamp]
  # A transforms tick within this of the last one handed over is a stopped recording's.
  @stale_transforms_ms 500

  @impl Exporter
  def describe(_options), do: %{id: :ros2_bag, name: "ROS 2 · Bag"}

  @impl Exporter
  def delivery(_options), do: {:queue, @queue}

  @impl Exporter
  def children(options),
    do: [
      {Disks,
       Keyword.merge(
         [name: Disks, internal: root(options), eject_timeout_ms: @eject_timeout_ms],
         disks_options(options)
       )}
    ]

  defp disks_options(options), do: Keyword.get(options, :disks, [])

  defp disks(options), do: Keyword.get(disks_options(options), :name, Disks)

  defp root(options), do: Keyword.get(options, :root, @root)

  defp eject_timeout_ms(options),
    do: Keyword.get(disks_options(options), :eject_timeout_ms, @eject_timeout_ms)

  defp free_floor(options), do: Keyword.get(options, :free_floor_bytes, @free_floor_bytes)

  @typedoc "A recording in progress, as `start_recording/3` and `recording/1` answer it."
  @type recording :: %{
          name: String.t(),
          folder: Path.t(),
          folders: [Path.t()],
          disk: String.t(),
          preset: Preset.name(),
          clock: Clock.mode() | :automatic,
          clock_in_use: Clock.mode(),
          synchronized: boolean(),
          started_at: DateTime.t(),
          duration_ms: non_neg_integer(),
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          messages: non_neg_integer(),
          dropped: %{String.t() => pos_integer()}
        }

  @typedoc "A stopped recording, as `stop_recording/2` answers it."
  @type summary :: %{
          folder: Path.t(),
          folders: [Path.t()],
          bytes: non_neg_integer(),
          files: non_neg_integer(),
          messages: non_neg_integer(),
          dropped: %{String.t() => pos_integer()}
        }

  @typedoc "Why a call through the runner got no answer (`VisionCore.Exporter.Runner.call/3`)."
  @type unanswered :: :not_running | :timeout | :unknown_call | {:failed, String.t()}

  @doc "The presets a recording records, `VisionCore.Ros2.BagExporter.Preset.names/0`."
  @spec presets() :: [Preset.name()]
  def presets, do: Preset.names()

  @doc "The clocks a recording is started with (`VisionCore.Ros2.Bag.Clock`)."
  @spec clocks() :: [Clock.mode() | :automatic]
  def clocks, do: @clocks

  @doc """
  Starts a recording of `preset` with `clock` on the exporter `runner`
  runs, answering it as `recording/1` does; `{:error, :busy}` while
  recording, `{:error, {:no_disk, reason}}` with no disk to record on,
  and `{:error, {:failed, reason}}` when the folder cannot be written or
  the preset's messages cannot be built.
  """
  @spec start_recording(GenServer.server(), Preset.name(), Clock.mode() | :automatic) ::
          {:ok, recording()}
          | {:error, :busy | {:no_disk, String.t()} | {:failed, String.t()} | unanswered()}
  def start_recording(runner, preset, clock) when clock in @clocks do
    true = preset in Preset.names()
    Runner.call(runner, {:start, preset, clock}, @start_timeout_ms)
  end

  @doc """
  Closes the recording in progress named `name`, answering its first
  folder, every part's folder, the bytes of its closed files on the
  disks still mounted, its files, and the messages and drops counted
  when it was asked; `{:error, :not_recording}` while idle and
  `{:error, :other_recording}` while another records.
  """
  @spec stop_recording(GenServer.server(), String.t()) ::
          {:ok, summary()} | {:error, :not_recording | :other_recording | unanswered()}
  def stop_recording(runner, name), do: Runner.call(runner, {:stop, name}, @stop_timeout_ms)

  @doc """
  The recording in progress: its name, its first folder and every
  part's, the disk it records on, its preset, the clock chosen and the
  one in use, whether the clock was synchronized, its start and
  duration, and the bytes, files, messages and drops by topic counted so
  far; `nil` while idle.
  """
  @spec recording(GenServer.server()) :: {:ok, recording() | nil} | {:error, unanswered()}
  def recording(runner), do: Runner.call(runner, :recording, @recording_timeout_ms)

  @impl Exporter
  def check(options) do
    presets = Keyword.get(options, :presets, [])

    root = root(options)

    chunk_interval_ms =
      options |> Keyword.get(:recording, []) |> Keyword.get(:chunk_interval_ms, 0)

    cond do
      (unknown = Keyword.keys(options) -- @known_options) != [] ->
        {:error,
         "it takes no option #{Enum.map_join(unknown, ", ", &inspect/1)}, only " <>
           Enum.map_join(@known_options, ", ", &inspect/1)}

      not (is_list(presets) and Keyword.keyword?(presets)) ->
        {:error, "its presets: is not a keyword list: #{inspect(presets)}"}

      not Keyword.keyword?(disks_options(options)) ->
        {:error, "its disks: is not a keyword list: #{inspect(disks_options(options))}"}

      Keyword.has_key?(disks_options(options), :internal) ->
        {:error, "its disks: sets internal:, which root: sets"}

      not match?(floor when is_integer(floor) and floor >= 0, free_floor(options)) ->
        {:error, "its free_floor_bytes: is not a count of bytes: #{inspect(free_floor(options))}"}

      not (is_binary(root) and root != "") ->
        {:error, "its root: is not a folder's path: #{inspect(root)}"}

      chunk_interval_ms not in 0..(eject_timeout_ms(options) - 1)//1 ->
        {:error,
         "its recording: chunk_interval_ms: is not a time in ms below " <>
           "#{eject_timeout_ms(options)}, " <>
           "the time an eject waits for the recording to leave the disk: " <>
           inspect(chunk_interval_ms)}

      (unknown = Keyword.keys(presets) -- Preset.names()) != [] ->
        {:error,
         "its presets: names #{Enum.map_join(unknown, ", ", &inspect/1)}, " <>
           "which is no preset: #{allowed(Preset.names())}"}

      true ->
        Enum.find_value(Preset.names(), :ok, &check_preset(&1, options))
    end
  end

  defp check_preset(preset, options) do
    with :ok <- check_own_options(preset_options(preset, options)),
         {:ok, _max_hz} <- Preset.max_hz(preset_options(preset, options)),
         :ok <- ZenohExporter.check(zenoh_options(preset, options)) do
      nil
    else
      {:error, reason} -> {:error, "its #{preset} preset: #{reason}"}
    end
  end

  defp check_own_options(preset_options) do
    case Enum.filter(@own_zenoh_options, &Keyword.has_key?(preset_options, &1)) do
      [] ->
        :ok

      set ->
        {:error,
         "sets #{Enum.map_join(set, ", ", &"#{&1}:")}, which the bag exporter sets itself"}
    end
  end

  defp allowed(names), do: Enum.map_join(names, ", ", &Atom.to_string/1)

  @impl Exporter
  def outputs(options) do
    config = config(options)

    Preset.names()
    |> Enum.flat_map(&ZenohExporter.outputs(zenoh_options(&1, options)))
    |> Enum.uniq_by(&key(&1, config))
  end

  # The key an output is published under, which two names of one camera output share.
  defp key(output, config), do: Exporter.output_key(output, config) || output

  # The vehicle's options of `preset`, else the preset's own.
  defp preset_options(preset, options) do
    Keyword.get_lazy(Keyword.get(options, :presets, []), preset, fn ->
      Preset.options(preset, config(options))
    end)
  end

  # A preset's options as `ZenohExporter` takes them, the exporter's own in place of the preset's.
  defp zenoh_options(preset, options) do
    [config: config(options), link: false, services: false] ++
      Keyword.take(options, [:jpeg_codec]) ++
      Keyword.drop(preset_options(preset, options), [:max_hz | @own_zenoh_options])
  end

  defp config(options) do
    Keyword.get_lazy(options, :config, &VisionCore.Application.active_config/0) ||
      %VisionCore.Config{}
  end

  @impl Exporter
  def init(options) do
    {:ok,
     %{
       options: options,
       config: config(options),
       disks: disks(options),
       free_floor_bytes: free_floor(options),
       recording: nil,
       stopped: nil,
       in_flight: %{}
     }}
  end

  @impl Exporter
  def handle_call({:start, _preset, _clock}, _from, %{recording: %{}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:start, preset, clock}, _from, state) do
    case begin_recording(state, preset, clock) do
      {:ok, recording} ->
        {:reply, {:ok, facts(recording)}, %{state | recording: recording, stopped: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, _name}, _from, %{recording: nil} = state),
    do: {:reply, {:error, :not_recording}, state}

  def handle_call({:stop, name}, _from, %{recording: recording} = state) do
    if Path.basename(recording.dir) == name do
      {summary, state} = end_recording(state)
      {:reply, {:ok, summary}, state}
    else
      {:reply, {:error, :other_recording}, state}
    end
  end

  def handle_call(:recording, _from, %{recording: nil} = state), do: {:reply, {:ok, nil}, state}

  def handle_call(:recording, _from, %{recording: recording} = state),
    do: {:reply, {:ok, facts(recording)}, state}

  defp begin_recording(state, preset, clock_choice) do
    case Disks.next(state.disks, state.free_floor_bytes) do
      {:ok, disk} -> begin_recording(state, preset, clock_choice, disk)
      {:error, reason} -> {:error, {:no_disk, reason}}
    end
  end

  defp begin_recording(state, preset, clock_choice, disk) do
    started_at = DateTime.utc_now()
    name = folder_name(state.disks, disk.recordings_path, started_at, preset)
    dir = Path.join(disk.recordings_path, name)
    synchronized? = Keyword.get(state.options, :clock_synchronized?)
    clock_options = if synchronized?, do: [synchronized?: synchronized?], else: []
    clock = Clock.new(clock_choice, System.monotonic_time(:nanosecond), clock_options)

    recording_options =
      state.options
      |> Keyword.get(:recording, [])
      |> Keyword.take(@recording_options)
      |> Keyword.merge(
        dir: dir,
        name: name,
        start_time_ns: Clock.start_time_ns(clock),
        disks: state.disks,
        disk: disk.uuid,
        free_floor_bytes: state.free_floor_bytes,
        attachments: attachments(state),
        metadata: metadata(preset, clock_choice, clock, started_at)
      )

    {:ok, pid} = Recording.start_link(recording_options)

    recording = %{
      pid: pid,
      dir: dir,
      disk: disk.uuid,
      preset: preset,
      clock_choice: clock_choice,
      clock: clock,
      started_at: started_at,
      started_ms: System.monotonic_time(:millisecond),
      transforms_ms: nil
    }

    case build_recording(state, recording) do
      {:ok, recording} ->
        {:ok, recording}

      {:error, reason} ->
        Recording.stop(pid)
        {:error, {:failed, reason}}
    end
  end

  # Any failure once the recording has started, an exit included, fails the start.
  defp build_recording(state, recording) do
    case Recording.status(recording.pid) do
      %{error: nil} -> start_building(state, recording)
      %{error: reason} -> {:error, reason}
    end
  catch
    kind, reason ->
      {:error,
       "cannot build the #{recording.preset} preset's messages: " <>
         Exception.format_banner(kind, reason)}
  end

  # The `ZenohExporter` state that builds the recording's messages, and the outputs handed to it.
  defp start_building(state, %{pid: pid, clock: clock} = recording) do
    publish = fn topic, module, message, _options ->
      log_time = Clock.time_ns(clock, System.monotonic_time(:nanosecond))
      Recording.write(pid, topic, module, message, log_time)
    end

    options =
      [publish: publish, stamp: Clock.stamp(clock)] ++
        zenoh_options(recording.preset, state.options)

    preset_keys = MapSet.new(ZenohExporter.outputs(options), &key(&1, state.config))

    routed =
      for output <- outputs(state.options), key(output, state.config) in preset_keys, do: output

    {:ok, max_hz} = Preset.max_hz(preset_options(recording.preset, state.options))

    case ZenohExporter.init(options) do
      {:ok, building} ->
        check_later(pid)

        {:ok,
         Map.merge(recording, %{
           building: building,
           routed: MapSet.new(routed),
           max_hz: max_hz,
           next_slot_ns: %{}
         })}

      {:error, reason} ->
        {:error, "cannot build the #{recording.preset} preset's messages: #{reason}"}
    end
  end

  # A name no recording on a mounted disk has, as `VisionCore.Recordings` joins their parts, nor any file in `root`.
  defp folder_name(disks, root, started_at, preset) do
    base = Calendar.strftime(started_at, "%Y%m%dT%H%M%SZ") <> "_#{preset}"
    taken = taken_names(disks)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1) and not File.exists?(Path.join(root, &1))))
  end

  defp taken_names(disks) do
    for %{recordings_path: recordings} <- Disks.list(disks),
        is_binary(recordings),
        {:ok, folders} <- [File.ls(recordings)],
        folder <- folders,
        into: MapSet.new(),
        do: folder |> VisionCore.Recording.part_of() |> elem(0)
  end

  defp check_later(pid),
    do: Process.send_after(self(), {__MODULE__, :check, pid}, @check_interval_ms)

  defp facts(recording) do
    status = Recording.status(recording.pid) || ended_status(recording)

    %{
      name: Path.basename(recording.dir),
      folder: recording.dir,
      folders: status.folders,
      disk: status.disk,
      preset: recording.preset,
      clock: recording.clock_choice,
      clock_in_use: recording.clock.mode,
      synchronized: recording.clock.synchronized,
      started_at: recording.started_at,
      duration_ms: System.monotonic_time(:millisecond) - recording.started_ms,
      bytes: status.bytes,
      files: status.files,
      messages: status.messages |> Map.values() |> Enum.sum(),
      dropped: status.dropped
    }
  end

  defp ended_status(recording),
    do: %{
      bytes: 0,
      files: 0,
      messages: %{},
      dropped: %{},
      disk: recording.disk,
      folders: [recording.dir]
    }

  # Closes the recording; the encodes in flight are answered once their tasks are done.
  defp end_recording(%{recording: recording} = state, error \\ nil) do
    status = Recording.status(recording.pid)
    Recording.stop(recording.pid)
    summary = summary(recording, status)

    {summary,
     %{
       state
       | recording: nil,
         stopped: error && Map.put(summary, :error, error),
         in_flight: Map.merge(state.in_flight, ZenohExporter.publishing(recording.building))
     }}
  end

  defp summary(recording, status) do
    status = status || ended_status(recording)

    %{
      folder: recording.dir,
      folders: status.folders,
      bytes: status.folders |> Enum.map(&folder_bytes/1) |> Enum.sum(),
      files: status.files,
      messages: status.messages |> Map.values() |> Enum.sum(),
      dropped: status.dropped
    }
  end

  # The files' size once closed: the recording's count stops at its last chunk.
  defp folder_bytes(dir) do
    dir
    |> Path.join("*.mcap")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _reason} -> 0
      end
    end)
    |> Enum.sum()
  end

  @impl Exporter
  def handle_output(output, value, %{recording: %{} = recording} = state) do
    with true <- MapSet.member?(recording.routed, output),
         {:take, next_slot_ns} <- slot(recording, output, value) do
      output
      |> ZenohExporter.handle_output(value, recording.building)
      |> building(put_in(state.recording.next_slot_ns, next_slot_ns))
    else
      _not_recorded -> {:ok, state}
    end
  end

  def handle_output(_output, _value, state), do: {:ok, state}

  # Takes a value at or past its output's next slot; the first, or one a slot late, starts them anew.
  defp slot(%{next_slot_ns: next_slot_ns} = recording, output, value) do
    case Map.fetch(recording.max_hz, Preset.kind(output)) do
      {:ok, max_hz} ->
        period_ns = round(1_000_000_000 / max_hz)
        capture_ns = capture_ns(value)
        next_ns = next_slot_ns[output]

        cond do
          next_ns && capture_ns < next_ns ->
            :skip

          next_ns && capture_ns - next_ns < period_ns ->
            {:take, %{next_slot_ns | output => next_ns + period_ns}}

          true ->
            {:take, Map.put(next_slot_ns, output, capture_ns + period_ns)}
        end

      :error ->
        {:take, next_slot_ns}
    end
  end

  defp capture_ns(%Pair{} = pair), do: Pair.capture_ns(pair)
  defp capture_ns(%Frame{capture_ns: capture_ns}), do: capture_ns
  defp capture_ns({source, _detections}), do: capture_ns(source)
  defp capture_ns({%Frame{capture_ns: capture_ns}, _labels, _clouds}), do: capture_ns

  defp building({:ok, building}, state), do: {:ok, put_in(state.recording.building, building)}
  defp building({:busy, building}, state), do: {:busy, put_in(state.recording.building, building)}

  defp building({:ready, output, building}, state),
    do: {:ready, output, put_in(state.recording.building, building)}

  @impl Exporter
  def handle_info({__MODULE__, :check, pid}, %{recording: %{pid: pid}} = state) do
    case Recording.status(pid) do
      %{error: nil} ->
        check_later(pid)
        {:ok, state}

      ended ->
        reason = (ended && ended.error) || "the recording process stopped"
        Logger.error("#{inspect(__MODULE__)} #{state.recording.dir}: #{reason}")
        {_summary, state} = end_recording(state, reason)
        {:ok, state}
    end
  end

  def handle_info({__MODULE__, :check, _pid}, state), do: {:ok, state}

  def handle_info({reference, _answer}, state) when is_map_key(state.in_flight, reference),
    do: answered(reference, state)

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state)
      when is_map_key(state.in_flight, reference),
      do: answered(reference, state)

  def handle_info(:publish_transforms, %{recording: %{} = recording} = state) do
    now_ms = System.monotonic_time(:millisecond)

    if recording.transforms_ms && now_ms - recording.transforms_ms < @stale_transforms_ms,
      do: {:ok, state},
      else:
        :publish_transforms
        |> ZenohExporter.handle_info(recording.building)
        |> building(put_in(state.recording.transforms_ms, now_ms))
  end

  def handle_info(message, %{recording: %{} = recording} = state),
    do: message |> ZenohExporter.handle_info(recording.building) |> building(state)

  def handle_info(_message, state), do: {:ok, state}

  defp answered(reference, state) do
    Process.demonitor(reference, [:flush])
    {output, in_flight} = Map.pop(state.in_flight, reference)
    {:ready, output, %{state | in_flight: in_flight}}
  end

  @impl Exporter
  def status(%{recording: nil, stopped: nil}), do: {:ok, "Idle"}

  def status(%{recording: nil, stopped: stopped}),
    do: {:warning, "Stopped: #{stopped.error} (#{Path.basename(stopped.folder)})"}

  def status(%{recording: recording}) do
    status = Recording.status(recording.pid) || ended_status(recording)

    level = if status.dropped == %{}, do: :ok, else: :warning
    {level, recording_text(recording, status)}
  end

  defp recording_text(recording, status) do
    described = Clock.describe(recording.clock)
    synchronized = if described.synchronized, do: "synchronized", else: "not synchronized"
    messages = status.messages |> Map.values() |> Enum.sum()

    "Recording #{recording.preset} since " <>
      Calendar.strftime(recording.started_at, "%H:%M:%S UTC") <>
      " (#{duration(System.monotonic_time(:millisecond) - recording.started_ms)}) " <>
      "on #{status.disk}, clock #{described.clock}, #{synchronized} (#{recording.clock_choice}): " <>
      "#{size(status.bytes)} in #{count(status.files, "file")}, " <>
      "#{count(messages, "message")}" <> dropped_text(status.dropped)
  end

  defp dropped_text(dropped) when dropped == %{}, do: ""

  defp dropped_text(dropped),
    do: "; dropped " <> Enum.map_join(Enum.sort(dropped), ", ", fn {t, n} -> "#{t} #{n}" end)

  defp duration(ms) do
    seconds = div(ms, 1_000)

    case {div(seconds, 3_600), div(rem(seconds, 3_600), 60), rem(seconds, 60)} do
      {0, 0, s} -> "#{s} s"
      {0, m, s} -> "#{m} min #{s} s"
      {h, m, _s} -> "#{h} h #{m} min"
    end
  end

  defp size(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp size(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  defp size(bytes) when bytes < 1_000_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp size(bytes), do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  @impl Exporter
  def terminate(_reason, %{recording: %{pid: pid}}), do: Recording.stop(pid)
  def terminate(_reason, _state), do: :ok

  defp attachments(state) do
    calibration_attachments(state.config) ++
      [{"parameters.json", "application/json", Jason.encode!(parameters(state.options))}]
  end

  # The calibration files in use of every target, each once: a pose's are its cameras' too.
  defp calibration_attachments(config) do
    for target <- VisionCore.Calibration.targets(config),
        {:ok, in_use} <- [VisionCore.Calibration.in_use(config, target.id)],
        %{file: file, yaml: yaml} <- in_use.cameras ++ List.wrap(in_use.pose),
        is_binary(yaml),
        uniq: true,
        do: {"calibration/#{file}", "application/yaml", yaml}
  end

  defp parameters(options) do
    groups = Keyword.get(options, :parameters, &VisionCore.Parameters.groups/0)

    groups
    |> read_groups()
    |> Enum.map(fn %Group{} = group ->
      %{
        id: group.id,
        name: group.name,
        pipeline: group.pipeline,
        parameters:
          Enum.map(group.parameters, fn parameter ->
            %{
              id: parameter.id,
              name: parameter.name,
              type: parameter.type,
              value: json_value(parameter.value),
              default: json_value(parameter.default),
              saved: json_value(parameter.saved),
              state: parameter.state
            }
          end)
      }
    end)
  end

  defp read_groups(groups) do
    groups.()
  catch
    :exit, _reason -> []
  end

  defp json_value(value) when is_tuple(value), do: inspect(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp metadata(preset, clock_choice, clock, started_at) do
    described = Clock.describe(clock)
    firmware = FirmwareInfo.current()

    %{
      "preset" => Atom.to_string(preset),
      "clock" => Atom.to_string(clock_choice),
      "clock_in_use" => described.clock,
      "clock_synchronized" => to_string(described.synchronized),
      "started_at" => DateTime.to_iso8601(started_at),
      "vehicle" => firmware.vehicle,
      "firmware_revision" => firmware.revision,
      "firmware_target" => firmware.target,
      "nerves_system" => firmware.nerves_system,
      "nerves_system_version" => firmware.nerves_system_version
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
