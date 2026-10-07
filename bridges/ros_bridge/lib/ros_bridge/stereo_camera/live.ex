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

  alias Ros2.DiagnosticMsgs.Msg.DiagnosticArray
  alias Ros2.StdMsgs.Msg.{Float64, Header}
  alias RosBridge.Camera.Frame
  alias RosBridge.Timing
  alias RosBridge.ZenohClient

  @plot_period_ms 200
  @diagnostics_period_ms 1_000
  @stale_ms 2_000
  @max_sync_offset_ms 1.0
  @recent_frames 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
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
       offsets: [],
       window: []
     }}
  end

  @impl true
  def handle_cast({:camera_frame, %Frame{label: label, capture_ns: t}}, state) do
    side = String.to_existing_atom(label)
    other = if side == :left, do: :right, else: :left

    offsets =
      case pair_offset(side, t, state.recent[other], state.half_period_ns) do
        nil -> state.offsets
        offset_ns -> [offset_ns / 1.0e6 | state.offsets]
      end

    recent = Map.update!(state.recent, side, &Enum.take([t | &1], @recent_frames))
    {:noreply, %{state | recent: recent, offsets: offsets}}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:plot, state) do
    Process.send_after(self(), :plot, @plot_period_ms)

    if state.offsets != [],
      do: publish_float("#{state.prefix}/live/sync_offset_ms", median(state.offsets))

    for {side, live} <- lives(state), live do
      for {key, value} <- Map.take(live, [:exposure_time_us, :analogue_gain]),
          do: publish_float("#{state.prefix}/live/#{side}/#{key}", value)
    end

    {:noreply, %{state | offsets: [], window: Enum.take(state.offsets ++ state.window, 150)}}
  end

  def handle_info(:diagnostics, state) do
    Process.send_after(self(), :diagnostics, @diagnostics_period_ms)
    lives = lives(state)
    now_ms = System.system_time(:millisecond)

    statuses =
      Enum.map([:left, :right], &camera_status(state, &1, lives[&1], now_ms)) ++
        [sync_status(state, lives, now_ms)]

    message = %DiagnosticArray{
      header: %Header{stamp: Timing.time_message_for(System.monotonic_time(:nanosecond))},
      status: statuses
    }

    ZenohClient.publish("/diagnostics", DiagnosticArray, message)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Right minus left capture time of the frame at `t` and the nearest of
  the other camera's `recent` frames, or nil when none is within
  `half_period_ns`. Pure.
  """
  def pair_offset(side, t, recent, half_period_ns) do
    case Enum.min_by(recent, &abs(&1 - t), fn -> nil end) do
      nil -> nil
      t_other when abs(t_other - t) >= half_period_ns -> nil
      t_other when side == :right -> t - t_other
      t_other -> t_other - t
    end
  end

  defp lives(state) do
    if function_exported?(state.driver, :live, 1),
      do: Map.new(state.servers, fn {side, server} -> {side, state.driver.live(server)} end),
      else: %{left: nil, right: nil}
  end

  defp camera_status(state, side, live, now_ms) do
    base = %{name: "#{state.prefix} #{side} camera", hardware_id: "#{state.prefix}_#{side}"}

    cond do
      is_nil(live) or now_ms - live.received_ms > @stale_ms ->
        Map.merge(base, %{level: :stale, message: "no frame metadata"})

      state.sync[side] && live[:sync_ready] == false ->
        Map.merge(base, %{
          level: :warn,
          message: "waiting for camera sync",
          values: camera_values(live)
        })

      true ->
        Map.merge(base, %{level: :ok, message: camera_summary(live), values: camera_values(live)})
    end
  end

  defp camera_summary(live) do
    exposure =
      if live[:exposure_time_us], do: "#{format(live.exposure_time_us / 1000)} ms", else: "?"

    gain = if live[:analogue_gain], do: format(live.analogue_gain), else: "?"
    "exposure #{exposure}, gain #{gain}"
  end

  defp camera_values(live) do
    [
      {"exposure time (us)", live[:exposure_time_us]},
      {"analogue gain", live[:analogue_gain]},
      {"digital gain", live[:digital_gain]},
      {"lens position (dioptres)", live[:lens_position]},
      {"frame duration (us)", live[:frame_duration_us]},
      {"colour temperature (K)", live[:colour_temperature]},
      {"sync ready", live[:sync_ready]},
      {"sync timer (us)", live[:sync_timer_us]}
    ]
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {key, format(value)} end)
  end

  defp sync_status(state, lives, now_ms) do
    base = %{name: "#{state.prefix} camera sync", hardware_id: state.prefix}
    window = state.window
    roles = "left #{state.sync.left || "free"}, right #{state.sync.right || "free"}"
    ready = for side <- [:left, :right], state.sync[side], do: get_in(lives, [side, :sync_ready])

    fresh =
      Enum.all?([:left, :right], fn side ->
        lives[side] && now_ms - lives[side].received_ms <= @stale_ms
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
