defmodule VisionCore.Ros2.Exporter.Diagnostics do
  @moduledoc """
  What a stereo unit's cameras actually do, next to the settings asked
  for in its parameters (`VisionCore.Stereo.Parameters`):

    * `/diagnostics` (`diagnostic_msgs/DiagnosticArray`), every second:
      one status per camera with what libcamera applied (shutter, gains,
      focus, frame duration, colour temperature, sync), stale when the
      camera stops reporting, and one for the pair's sync with the time
      between the two cameras' frames, a warning above 1 ms
    * `<prefix>/live/sync_offset_ms` and, per camera,
      `<prefix>/live/<side>/exposure_time_us` and `.../analogue_gain`
      (`std_msgs/Float64`), five times a second, for plotting

  The sync offset is measured on every pair of frames taken less than
  half a frame period apart, right minus left, with
  `VisionCore.Stereo.Sync`, as the stereo unit measures it for
  `VisionCore.Status` (`VisionCore.Stereo.Pairer.sync/1`); this helper
  keeps a measurement of its own because its plot takes the offsets
  since the last one, and so that it reports on cameras whose unit gave
  up. The diagnostic summarises the recent pairs, none once no pair
  formed for two seconds (`VisionCore.Stereo.Sync.summary/2`).

  `VisionCore.Ros2.Exporter` starts it as a helper under its own
  supervisor when it publishes a stereo unit. It subscribes to the
  cameras' frames itself: the exporter is handed the newest frame of
  each camera only, and the sync is measured on every one. A camera that
  is down, as when the stereo unit gave up, reads as stale.

  ## Options

    * `:driver` — the cameras' `VisionCore.Camera` module (required),
      whose `name_for/1` names each side and whose `live/1`, when it has
      one, reports what the camera applied.
    * `:topic_prefix` (`"stereo"`), `:fps` (30).
    * `:left`, `:right` — each camera's `:sync` role, when it has one.
    * `:publish` (`&VisionCore.Ros2.ZenohClient.publish/4`) — sends one
      message, as `VisionCore.Ros2.Exporter`'s does.
    * `:name` (this module) — the name it registers under.
  """

  use GenServer

  alias Ros2Zenoh.DiagnosticMsgs.Msg.DiagnosticArray
  alias Ros2Zenoh.StdMsgs.Msg.{Float64, Header}
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Ros2.{Stamp, ZenohClient}
  alias VisionCore.Stereo.Sync

  @default_topic_prefix "stereo"
  @default_fps 30
  @plot_period_ms 200
  @diagnostics_period_ms 1_000
  @stale_ms 2_000
  @max_sync_offset_ms 1.0

  @typedoc "A message to publish: its topic, its module and the message."
  @type message :: {String.t(), module(), struct()}

  @typedoc """
  What each camera reported last (`live/1` of its driver), `nil` for a
  camera that reported nothing.
  """
  @type live_metadata :: %{left: map() | nil, right: map() | nil}

  @doc "Starts listening to both cameras of the unit; see the module doc."
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl GenServer
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    Code.ensure_loaded(driver)

    servers = %{
      left: driver.name_for("left"),
      right: driver.name_for("right")
    }

    Enum.each(servers, fn {_side, server} -> :ok = Outputs.subscribe({:camera_frame, server}) end)
    Process.send_after(self(), :plot, @plot_period_ms)
    Process.send_after(self(), :diagnostics, @diagnostics_period_ms)

    {:ok,
     %{
       prefix: Keyword.get(opts, :topic_prefix, @default_topic_prefix),
       driver: driver,
       servers: servers,
       roles: %{left: get_in(opts, [:left, :sync]), right: get_in(opts, [:right, :sync])},
       publish: Keyword.get(opts, :publish, &ZenohClient.publish/4),
       sync: Sync.new(Keyword.get(opts, :fps, @default_fps)),
       offsets_ms: []
     }}
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{label: label, capture_ns: capture_ns}}, state)
      when label in ["left", "right"] do
    side = String.to_existing_atom(label)

    case Sync.add(state.sync, side, capture_ns, System.monotonic_time(:millisecond)) do
      {nil, sync} ->
        {:noreply, %{state | sync: sync}}

      {offset_ms, sync} ->
        {:noreply, %{state | sync: sync, offsets_ms: [offset_ms | state.offsets_ms]}}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:plot, state) do
    Process.send_after(self(), :plot, @plot_period_ms)

    state.prefix
    |> plot_messages(state.offsets_ms, live_metadata(state))
    |> Enum.each(&publish(state, &1))

    {:noreply, %{state | offsets_ms: []}}
  end

  def handle_info(:diagnostics, state) do
    Process.send_after(self(), :diagnostics, @diagnostics_period_ms)

    message =
      diagnostic_array(
        state.prefix,
        state.roles,
        Sync.summary(state.sync, System.monotonic_time(:millisecond)),
        live_metadata(state),
        System.system_time(:millisecond),
        Stamp.stamp_from_monotonic(System.monotonic_time(:nanosecond))
      )

    publish(state, {"/diagnostics", DiagnosticArray, message})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The plotted values of the unit under `prefix`: the median of
  `offsets_ms`, the offsets measured since the last plot, when there
  are any, then each camera's exposure and gain in `live_metadata`.
  """
  @spec plot_messages(String.t(), [float()], live_metadata()) :: [message()]
  def plot_messages(prefix, offsets_ms, live_metadata) do
    sync =
      if offsets_ms == [],
        do: [],
        else: [float_message("#{prefix}/live/sync_offset_ms", Sync.median(offsets_ms))]

    cameras =
      for side <- [:left, :right],
          metadata = live_metadata[side],
          key <- [:exposure_time_us, :analogue_gain],
          is_number(metadata[key]),
          do: float_message("#{prefix}/live/#{side}/#{key}", metadata[key])

    sync ++ cameras
  end

  @doc """
  The `/diagnostics` message of the unit under `prefix` at `now_ms`,
  stamped `stamp`: one status per camera, from its `live_metadata` and
  its sync role in `roles`, then the pair's sync, `sync`, the recent
  right minus left offsets summarised.
  """
  @spec diagnostic_array(
          String.t(),
          %{left: atom() | nil, right: atom() | nil},
          Sync.summary(),
          live_metadata(),
          integer(),
          struct()
        ) :: struct()
  def diagnostic_array(prefix, roles, sync, live_metadata, now_ms, stamp) do
    statuses =
      Enum.map([:left, :right], &camera_status(prefix, roles, &1, live_metadata[&1], now_ms)) ++
        [sync_status(prefix, roles, sync, live_metadata, now_ms)]

    %DiagnosticArray{header: %Header{stamp: stamp}, status: statuses}
  end

  defp live_metadata(%{driver: driver, servers: servers}) do
    if function_exported?(driver, :live, 1),
      do: Map.new(servers, fn {side, server} -> {side, live(driver, server)} end),
      else: %{left: nil, right: nil}
  end

  # A camera that is not running reported nothing.
  defp live(driver, server) do
    driver.live(server)
  catch
    :exit, _reason -> nil
  end

  defp camera_status(prefix, roles, side, live_metadata, now_ms) do
    base = %{name: "#{prefix} #{side} camera", hardware_id: "#{prefix}_#{side}"}

    cond do
      is_nil(live_metadata) or now_ms - live_metadata.received_ms > @stale_ms ->
        Map.merge(base, %{level: :stale, message: "no frame metadata"})

      roles[side] && live_metadata[:sync_ready] == false ->
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

  defp sync_status(prefix, roles, sync, live_metadata, now_ms) do
    base = %{name: "#{prefix} camera sync", hardware_id: prefix}
    labels = "left #{roles.left || "free"}, right #{roles.right || "free"}"

    ready =
      for side <- [:left, :right],
          roles[side],
          do: get_in(live_metadata, [side, :sync_ready])

    fresh =
      Enum.all?([:left, :right], fn side ->
        live_metadata[side] && now_ms - live_metadata[side].received_ms <= @stale_ms
      end)

    values =
      [{"roles", labels}] ++
        if sync.pairs == 0,
          do: [],
          else: [
            {"offset median (ms)", format(sync.offset_median_ms)},
            {"offset max (ms)", format(sync.offset_max_ms)},
            {"pairs measured", Integer.to_string(sync.pairs)}
          ]

    {level, message} =
      cond do
        not fresh or sync.pairs == 0 ->
          {:stale, "no frame pairs"}

        Enum.any?(ready, &(&1 != true)) ->
          {:warn, "cameras not synced"}

        abs(sync.offset_median_ms) > @max_sync_offset_ms ->
          {:warn, "frames #{format(sync.offset_median_ms)} ms apart"}

        true ->
          {:ok, "frames #{format(sync.offset_median_ms)} ms apart"}
      end

    Map.merge(base, %{level: level, message: message, values: values})
  end

  defp float_message(topic, value), do: {topic, Float64, %Float64{data: value * 1.0}}

  defp publish(state, {topic, module, message}), do: state.publish.(topic, module, message, [])

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
