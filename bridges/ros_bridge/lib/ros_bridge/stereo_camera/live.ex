defmodule RosBridge.StereoCamera.Live do
  @moduledoc """
  What a stereo unit's cameras actually do, next to the settings asked
  for in its parameters (`RosBridge.StereoCamera.Parameters`):

    * `/diagnostics` (`diagnostic_msgs/DiagnosticArray`), every second:
      one status per camera with what libcamera applied (shutter, gains,
      focus, frame duration, colour temperature, sync), stale when the
      camera stops reporting, and one for the pair's sync with the time
      between the two cameras' frames, a warning above 1 ms
    * `<prefix>/live/sync_offset_ms` and, per camera,
      `<prefix>/live/<side>/exposure_time_us` and `.../analogue_gain`
      (`std_msgs/Float64`), five times a second, for plotting

  The sync offset is measured on every pair of frames taken less than
  half a frame period apart, right minus left.
  """

  use GenServer

  alias Ros2Zenoh.DiagnosticMsgs.Msg.DiagnosticArray
  alias Ros2Zenoh.StdMsgs.Msg.{Float64, Header}
  alias RosBridge.{Timing, ZenohClient}
  alias RosBridge.Camera.Frame

  @plot_period_ms 200
  @diagnostics_period_ms 1_000
  @stale_ms 2_000
  @max_sync_offset_ms 1.0
  @recent_frame_count 4
  @sync_window_size 150

  @doc "Starts listening to both cameras of the unit; see the module doc."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    Code.ensure_loaded(driver)

    servers = %{
      left: driver.name_for("left"),
      right: driver.name_for("right")
    }

    Enum.each(servers, fn {_, server} -> driver.register_listener(server, self()) end)
    Process.send_after(self(), :plot, @plot_period_ms)
    Process.send_after(self(), :diagnostics, @diagnostics_period_ms)

    {:ok,
     %{
       prefix: Keyword.fetch!(opts, :topic_prefix),
       driver: driver,
       servers: servers,
       sync: %{left: get_in(opts, [:left, :sync]), right: get_in(opts, [:right, :sync])},
       half_period_ns: div(1_000_000_000, 2 * Keyword.get(opts, :fps, 30)),
       recent: %{left: [], right: []},
       offsets_ms: [],
       recent_offsets_ms: []
     }}
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{label: label, capture_ns: capture_ns}}, state) do
    side = String.to_existing_atom(label)
    other_side = if side == :left, do: :right, else: :left

    offsets_ms =
      case pair_offset(side, capture_ns, state.recent[other_side], state.half_period_ns) do
        nil -> state.offsets_ms
        offset_ns -> [offset_ns / 1.0e6 | state.offsets_ms]
      end

    recent = Map.update!(state.recent, side, &Enum.take([capture_ns | &1], @recent_frame_count))
    {:noreply, %{state | recent: recent, offsets_ms: offsets_ms}}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:plot, state) do
    Process.send_after(self(), :plot, @plot_period_ms)

    if state.offsets_ms != [],
      do: publish_float("#{state.prefix}/live/sync_offset_ms", median(state.offsets_ms))

    for {side, live_metadata} <- fetch_live_metadata(state), live_metadata do
      for {key, value} <- Map.take(live_metadata, [:exposure_time_us, :analogue_gain]),
          do: publish_float("#{state.prefix}/live/#{side}/#{key}", value)
    end

    recent_offsets_ms = Enum.take(state.offsets_ms ++ state.recent_offsets_ms, @sync_window_size)
    {:noreply, %{state | offsets_ms: [], recent_offsets_ms: recent_offsets_ms}}
  end

  def handle_info(:diagnostics, state) do
    Process.send_after(self(), :diagnostics, @diagnostics_period_ms)
    live_metadata = fetch_live_metadata(state)
    now_ms = System.system_time(:millisecond)

    statuses =
      Enum.map([:left, :right], &camera_status(state, &1, live_metadata[&1], now_ms)) ++
        [sync_status(state, live_metadata, now_ms)]

    message = %DiagnosticArray{
      header: %Header{stamp: Timing.stamp_from_monotonic(System.monotonic_time(:nanosecond))},
      status: statuses
    }

    ZenohClient.publish("/diagnostics", DiagnosticArray, message)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Right minus left capture time of the frame at `capture_ns` and the
  nearest of the other camera's `recent` frames, or nil when none is
  within `half_period_ns`. Pure.
  """
  def pair_offset(side, capture_ns, recent, half_period_ns) do
    case Enum.min_by(recent, &abs(&1 - capture_ns), fn -> nil end) do
      nil -> nil
      other_capture_ns when abs(other_capture_ns - capture_ns) >= half_period_ns -> nil
      other_capture_ns when side == :right -> capture_ns - other_capture_ns
      other_capture_ns -> other_capture_ns - capture_ns
    end
  end

  defp fetch_live_metadata(state) do
    if function_exported?(state.driver, :live, 1),
      do: Map.new(state.servers, fn {side, server} -> {side, state.driver.live(server)} end),
      else: %{left: nil, right: nil}
  end

  defp camera_status(state, side, live_metadata, now_ms) do
    base = %{name: "#{state.prefix} #{side} camera", hardware_id: "#{state.prefix}_#{side}"}

    cond do
      is_nil(live_metadata) or now_ms - live_metadata.received_ms > @stale_ms ->
        Map.merge(base, %{level: :stale, message: "no frame metadata"})

      state.sync[side] && live_metadata[:sync_ready] == false ->
        Map.merge(base, %{
          level: :warn,
          message: "waiting for camera sync",
          values: camera_values(live_metadata)
        })

      true ->
        Map.merge(base, %{
          level: :ok,
          message: camera_summary(live_metadata),
          values: camera_values(live_metadata)
        })
    end
  end

  defp camera_summary(live_metadata) do
    exposure =
      if live_metadata[:exposure_time_us],
        do: "#{format(live_metadata.exposure_time_us / 1000)} ms",
        else: "?"

    gain = if live_metadata[:analogue_gain], do: format(live_metadata.analogue_gain), else: "?"
    "exposure #{exposure}, gain #{gain}"
  end

  defp camera_values(live_metadata) do
    [
      {"exposure time (us)", live_metadata[:exposure_time_us]},
      {"analogue gain", live_metadata[:analogue_gain]},
      {"digital gain", live_metadata[:digital_gain]},
      {"lens position (dioptres)", live_metadata[:lens_position]},
      {"frame duration (us)", live_metadata[:frame_duration_us]},
      {"colour temperature (K)", live_metadata[:colour_temperature]},
      {"sync ready", live_metadata[:sync_ready]},
      {"sync timer (us)", live_metadata[:sync_timer_us]}
    ]
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {key, format(value)} end)
  end

  defp sync_status(state, live_metadata, now_ms) do
    base = %{name: "#{state.prefix} camera sync", hardware_id: state.prefix}
    window = state.recent_offsets_ms
    roles = "left #{state.sync.left || "free"}, right #{state.sync.right || "free"}"

    ready =
      for side <- [:left, :right],
          state.sync[side],
          do: get_in(live_metadata, [side, :sync_ready])

    fresh =
      Enum.all?([:left, :right], fn side ->
        live_metadata[side] && now_ms - live_metadata[side].received_ms <= @stale_ms
      end)

    values =
      [{"roles", roles}] ++
        if window == [],
          do: [],
          else: [
            {"offset median (ms)", format(median(window))},
            {"offset max (ms)", format(Enum.max_by(window, &abs/1))},
            {"pairs measured", Integer.to_string(length(window))}
          ]

    {level, message} =
      cond do
        not fresh or window == [] ->
          {:stale, "no frame pairs"}

        Enum.any?(ready, &(&1 != true)) ->
          {:warn, "cameras not synced"}

        abs(median(window)) > @max_sync_offset_ms ->
          {:warn, "frames #{format(median(window))} ms apart"}

        true ->
          {:ok, "frames #{format(median(window))} ms apart"}
      end

    Map.merge(base, %{level: level, message: message, values: values})
  end

  defp publish_float(topic, value),
    do: ZenohClient.publish(topic, Float64, %Float64{data: value * 1.0})

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
