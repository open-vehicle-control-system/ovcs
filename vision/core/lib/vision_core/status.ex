defmodule VisionCore.Status do
  @moduledoc """
  The vision unit's health at a glance, for the dashboard: each camera's
  frame rate and exposure, the pair's sync, the Hailo detector, the depth
  rate, the Zenoh session, the CPU's busy share (`VisionCore.SystemLoad`)
  and the share of time the stereo pipeline spent in its compiled Nx or
  native segments (`Pair` `:device_ms`). Where they run on the GPU, that time
  includes uploading the frames and waiting for the results, so it is
  not the GPU's busy share. `:alignment` is the rectified images' row
  offset (`Pair` `:alignment`) and `:sharpness` each camera's sharpness
  (`Pair` `:sharpness`), and `:quality` the depth's quality
  (`VisionCore.Stereo.Stage.Quality`'s metrics: the share of matched
  pixels, the disparity's mean and spread, and its jitter), each averaged
  over the tick's pairs; `nil` without any.

  Started last in `VisionCore.Supervisor`. Without a `:stereo`
  component the cameras and sync are reported absent and the depth rate
  is zero.

  Rates are counted over the last tick, one second by default (`:tick_ms`),
  and every subscriber receives `{:vision_status, snapshot}` each tick.
  """
  use GenServer

  alias VisionCore.Ros2.Stereo.Diagnostics
  alias VisionCore.Ros2.ZenohClient
  alias VisionCore.Stereo.Sources
  alias VisionCore.SystemLoad
  alias VisionCore.Detection.Backend.Hailo
  alias VisionCore.Stereo.Pair
  alias VisionCore.Camera.Frame

  @default_tick_ms 1_000
  @call_timeout_ms 200
  @camera_metadata_keys [:exposure_time_us, :analogue_gain, :lens_position, :colour_temperature]
  @quality_metrics %{
    valid: :matched_percent,
    mean_disp: :mean_disparity_px,
    std_disp: :spread_px,
    jitter: :jitter_px
  }

  @type camera :: %{required(:present) => boolean(), optional(atom()) => term()}
  @type snapshot :: %{
          cameras: %{left: camera(), right: camera()},
          sync: map(),
          hailo: :running | :absent | :failed,
          depth_hz: float(),
          zenoh: :connected | :disconnected,
          cpu_percent: float() | nil,
          stereo_segment_percent: float(),
          alignment: %{offset_rows: float(), band_offset_rows: [float()]} | nil,
          sharpness: %{left: float(), right: float()} | nil,
          quality:
            %{
              matched_percent: float(),
              mean_disparity_px: float(),
              spread_px: float(),
              jitter_px: float()
            }
            | nil
        }

  @doc """
  Starts the status server. Options: `:config`, the active
  `VisionCore.Config` (required), and `:tick_ms`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The unit's status now, with the rates of the last tick."
  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Sends the caller `{:vision_status, snapshot}` now and every tick until it exits."
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    sources = Sources.from_config(config)
    Process.send_after(self(), :tick, tick_ms)

    {:ok,
     %{
       tick_ms: tick_ms,
       sources: sources,
       monitors: Sources.register(sources),
       hailo_configured?: hailo_configured?(config),
       subscribers: %{},
       counts: %{left: 0, right: 0, depth: 0},
       device_ms: 0.0,
       cpu_times: SystemLoad.cpu_times(),
       cpu_percent: nil,
       stereo_segment_percent: 0.0,
       alignments: [],
       alignment: nil,
       sharpnesses: [],
       sharpness: nil,
       qualities: [],
       quality: nil,
       window_start_ms: now_ms(),
       rates_hz: %{left: 0.0, right: 0.0, depth: 0.0}
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    send(pid, {:vision_status, build_snapshot(state)})
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    state = %{count(state, :depth) | device_ms: state.device_ms + pair.device_ms}

    {:noreply,
     %{
       state
       | alignments: prepend(pair.alignment, state.alignments),
         sharpnesses: prepend(pair.sharpness, state.sharpnesses),
         qualities: prepend(quality(pair.metrics), state.qualities)
     }}
  end

  def handle_cast({:camera_frame, %Frame{label: label}}, state) when label in ["left", "right"],
    do: {:noreply, count(state, String.to_existing_atom(label))}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    state = close_window(state)
    snapshot = build_snapshot(state)
    Enum.each(Map.keys(state.subscribers), &send(&1, {:vision_status, snapshot}))
    {:noreply, state}
  end

  def handle_info({:register_source, source}, state),
    do: {:noreply, %{state | monitors: Sources.retry(source, state.monitors)}}

  def handle_info({:DOWN, monitor_reference, :process, pid, _reason}, state) do
    case Sources.down(monitor_reference, state.monitors) do
      {:ok, monitors} -> {:noreply, %{state | monitors: monitors}}
      :error -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp count(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  defp close_window(state) do
    now = now_ms()
    elapsed_ms = max(now - state.window_start_ms, 1)
    rates_hz = Map.new(state.counts, fn {key, count} -> {key, count * 1_000 / elapsed_ms} end)
    cpu_times = SystemLoad.cpu_times()

    %{
      state
      | rates_hz: rates_hz,
        counts: %{left: 0, right: 0, depth: 0},
        window_start_ms: now,
        cpu_percent: SystemLoad.cpu_percent(state.cpu_times, cpu_times),
        cpu_times: cpu_times,
        stereo_segment_percent: min(100 * state.device_ms / elapsed_ms, 100.0),
        device_ms: 0.0,
        alignment: mean_alignment(state.alignments),
        alignments: [],
        sharpness: mean_sharpness(state.sharpnesses),
        sharpnesses: [],
        quality: mean_quality(state.qualities),
        qualities: []
    }
  end

  defp prepend(nil, list), do: list
  defp prepend(value, list), do: [value | list]

  defp quality(metrics) do
    quality =
      for {name, value, _unit} <- metrics,
          key = @quality_metrics[name],
          into: %{},
          do: {key, value}

    if map_size(quality) == map_size(@quality_metrics), do: quality
  end

  defp mean_quality([]), do: nil

  defp mean_quality(qualities) do
    Map.new(Map.values(@quality_metrics), fn key ->
      {key, Enum.sum(Enum.map(qualities, & &1[key])) / length(qualities)}
    end)
  end

  defp mean_sharpness([]), do: nil

  defp mean_sharpness(sharpnesses) do
    mean = fn side -> Enum.sum(Enum.map(sharpnesses, & &1[side])) / length(sharpnesses) end
    %{left: mean.(:left), right: mean.(:right)}
  end

  defp mean_alignment([]), do: nil

  defp mean_alignment(alignments) do
    mean = fn values -> Enum.sum(values) / length(values) end

    %{
      offset_rows: alignments |> Enum.map(& &1.offset_rows) |> mean.(),
      band_offset_rows:
        alignments |> Enum.map(& &1.band_offset_rows) |> Enum.zip_with(& &1) |> Enum.map(mean)
    }
  end

  defp build_snapshot(state) do
    %{
      cameras: %{left: camera(state, :left), right: camera(state, :right)},
      sync: sync(state),
      hailo: hailo(state),
      depth_hz: state.rates_hz.depth,
      cpu_percent: state.cpu_percent,
      stereo_segment_percent: state.stereo_segment_percent,
      alignment: state.alignment,
      sharpness: state.sharpness,
      quality: state.quality,
      zenoh:
        if(call_within_timeout(&ZenohClient.connected?/0, false),
          do: :connected,
          else: :disconnected
        )
    }
  end

  defp camera(%{sources: []}, _side), do: %{present: false}

  defp camera(%{sources: [_pipeline, left, right]} = state, side) do
    {driver, server} = if side == :left, do: left, else: right

    if GenServer.whereis(server) do
      %{present: true, fps: state.rates_hz[side]}
      |> Map.merge(camera_metadata(driver, server))
    else
      %{present: false}
    end
  end

  defp camera_metadata(driver, server) do
    if function_exported?(driver, :live, 1),
      do:
        call_within_timeout(
          fn -> Map.take(driver.live(server) || %{}, @camera_metadata_keys) end,
          %{}
        ),
      else: %{}
  end

  defp sync(%{sources: []}), do: %{present: false}

  defp sync(_state) do
    call_within_timeout(fn -> Map.put(Diagnostics.sync(), :present, true) end, %{
      present: false
    })
  end

  defp hailo(%{hailo_configured?: false}), do: :absent

  defp hailo(_state),
    do: if(call_within_timeout(&Hailo.available?/0, false), do: :running, else: :failed)

  defp hailo_configured?(%VisionCore.Config{components: components}),
    do: Enum.any?(components, &hailo_component?/1)

  defp hailo_component?(:hailo_detector), do: true
  defp hailo_component?({:hailo_detector, _options}), do: true
  defp hailo_component?(:detector), do: true
  defp hailo_component?({:detector, options}), do: Keyword.get(options, :backend, Hailo) == Hailo
  defp hailo_component?(_component), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A callee stuck in its own work must not hold back the tick.
  defp call_within_timeout(fun, fallback) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          _kind, _reason -> fallback
        end
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, reply} -> reply
      _timeout -> fallback
    end
  end
end
