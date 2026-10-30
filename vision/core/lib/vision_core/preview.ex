defmodule VisionCore.Preview do
  @moduledoc """
  Live JPEG previews of the stereo unit for the dashboard: the `:left`
  and `:right` camera frames as captured, and the `:depth` map
  colourised.

  A subscriber receives `{:vision_preview, stream, jpeg}` and calls
  `ack/1` once it has handled the frame. Each subscriber has at most one
  unacknowledged frame and receives at most `:max_hz` frames a second;
  frames arriving in between replace each other, so a slow subscriber
  gets the latest frame, never a backlog.

  The depth map is colourised and encoded only when a depth subscriber
  is due a frame, once per pair whatever the number of subscribers.
  Pairs without a depth image are skipped, and so is a depth map
  that fails to encode, with one error logged until an encode succeeds.

  Started last in `VisionCore.Supervisor`; without a `:stereo`
  component it runs with nothing to preview.

  ## Options

    * `:config` — the active `VisionCore.Config` (required).
    * `:max_hz` (`10`) — frames per second per subscriber.
    * `:depth_range_m` (`0.0`) — the distance coloured blue; 0 colours
      blue only what is infinitely far, so the colours stay put from one
      frame to the next. Red is the nearest measured depths.

  `:max_hz` and `:depth_range_m` change while running with
  `set_options/1`, and are the stereo unit's ROS 2 parameters
  `<topic_prefix>.preview.*`.
    * `:depth_encoder` — `(VisionCore.Stereo.Pair.t() -> jpeg)`,
      replacing `encode_depth/2`.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.Pair
  alias VisionCore.Stereo.Sources

  @streams [:left, :right, :depth]
  @default_max_hz 10
  @default_depth_range_m 0.0

  @option_specs [
    max_hz: %{
      type: :integer,
      range: {1, 30},
      default: @default_max_hz,
      description: "Preview frames per second per viewer"
    },
    depth_range_m: %{
      type: :double,
      range: {0, 50},
      default: @default_depth_range_m,
      description: "Distance coloured blue, in metres; 0 for infinitely far"
    }
  ]
  @jpeg_quality 80

  @type stream :: :left | :right | :depth

  @doc "Starts the preview server; see the module doc for the options."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends the caller `stream`'s frames as `{:vision_preview, stream, jpeg}` until it exits."
  @spec subscribe(stream()) :: :ok
  def subscribe(stream) when stream in @streams,
    do: GenServer.call(__MODULE__, {:subscribe, self(), stream})

  @doc "Tells the server the caller has handled its last `stream` frame."
  @spec ack(stream()) :: :ok
  def ack(stream) when stream in @streams, do: GenServer.cast(__MODULE__, {:ack, self(), stream})

  @doc """
  The depth of `pair` as a colour JPEG, by 1/depth: the nearest measured
  depths are red, `range_m` and beyond blue (with 0, infinitely far),
  pixels without depth black. Coloured and encoded on the CPU by
  `VisionCore.Jpeg`, from the millimetre depth image.
  """
  @spec encode_depth(Pair.t(), float()) :: binary() | {:error, term()}
  def encode_depth(%Pair{depth: depth} = pair, range_m \\ @default_depth_range_m)
      when is_binary(depth) do
    {width, height} = Pair.size(pair)
    far_mm = round(range_m * 1_000)

    case VisionCore.Jpeg.encode_depth(depth, width, height, 0, far_mm, @jpeg_quality) do
      {:ok, jpeg} -> jpeg
      {:error, _reason} = error -> error
    end
  end

  @doc "The settings `set_options/1` takes, as `{key, spec}`."
  def option_specs, do: @option_specs

  @doc "The settings in force."
  def options, do: GenServer.call(__MODULE__, :options)

  @doc "Changes settings, or says why it cannot; none change on a refusal."
  @spec set_options(keyword()) :: {:ok, map()} | {:error, String.t()}
  def set_options(options), do: GenServer.call(__MODULE__, {:set_options, options})

  @impl GenServer
  def init(opts) do
    sources = opts |> Keyword.fetch!(:config) |> Sources.from_config()
    max_hz = Keyword.get(opts, :max_hz, @default_max_hz)

    {:ok,
     %{
       max_hz: max_hz,
       depth_range_m: Keyword.get(opts, :depth_range_m, @default_depth_range_m) * 1.0,
       interval_ms: div(1_000, max_hz),
       depth_encoder: Keyword.get(opts, :depth_encoder),
       monitors: Sources.register(sources),
       latest: Map.new(@streams, &{&1, %{sequence: 0, frame: nil}}),
       encoded_depth: {0, nil},
       depth_failure_logged: false,
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call(:options, _from, state),
    do: {:reply, Map.take(state, [:max_hz, :depth_range_m]), state}

  def handle_call({:set_options, options}, _from, state) do
    case Enum.find(options, fn {key, value} -> not valid_option?(key, value) end) do
      nil ->
        state =
          Enum.reduce(options, state, fn {key, value}, state -> put_option(state, key, value) end)

        {:reply, {:ok, Map.take(state, [:max_hz, :depth_range_m])}, state}

      {key, value} ->
        {:reply, {:error, "#{key}: invalid value #{inspect(value)}"}, state}
    end
  end

  def handle_call({:subscribe, pid, stream}, _from, state)
      when is_map_key(state.subscribers, {pid, stream}),
      do: {:reply, :ok, state}

  def handle_call({:subscribe, pid, stream}, _from, state) do
    subscriber = %{
      monitor: Process.monitor(pid),
      sequence: 0,
      awaiting_ack: false,
      sent_ms: nil,
      timer: nil
    }

    state = put_in(state.subscribers[{pid, stream}], subscriber)
    {:reply, :ok, deliver(state, {pid, stream})}
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{label: label} = frame}, state)
      when label in ["left", "right"],
      do: {:noreply, store_frame(state, String.to_existing_atom(label), frame)}

  def handle_cast({:stereo_pair, %Pair{depth: nil}}, state), do: {:noreply, state}

  def handle_cast({:stereo_pair, %Pair{} = pair}, state),
    do: {:noreply, store_frame(state, :depth, pair)}

  def handle_cast({:ack, pid, stream}, state) do
    key = {pid, stream}

    case state.subscribers do
      %{^key => _subscriber} ->
        state = put_in(state.subscribers[key].awaiting_ack, false)
        {:noreply, deliver(state, key)}

      _subscribers ->
        {:noreply, state}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:deliver, key}, state) do
    case state.subscribers do
      %{^key => _subscriber} ->
        state = put_in(state.subscribers[key].timer, nil)
        {:noreply, deliver(state, key)}

      _subscribers ->
        {:noreply, state}
    end
  end

  def handle_info({:register_source, source}, state),
    do: {:noreply, %{state | monitors: Sources.retry(source, state.monitors)}}

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, state) do
    case Sources.down(monitor_reference, state.monitors) do
      {:ok, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      :error ->
        subscribers =
          Map.reject(state.subscribers, fn {_key, subscriber} ->
            subscriber.monitor == monitor_reference
          end)

        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp store_frame(state, stream, frame) do
    state =
      update_in(state.latest[stream], fn latest ->
        %{sequence: latest.sequence + 1, frame: frame}
      end)

    state.subscribers
    |> Map.keys()
    |> Enum.filter(&match?({_pid, ^stream}, &1))
    |> Enum.reduce(state, &deliver(&2, &1))
  end

  defp deliver(state, {pid, stream} = key) do
    subscriber = state.subscribers[key]
    latest = state.latest[stream]
    now_ms = System.monotonic_time(:millisecond)

    cond do
      is_nil(latest.frame) or latest.sequence <= subscriber.sequence or subscriber.awaiting_ack or
          subscriber.timer != nil ->
        state

      subscriber.sent_ms != nil and now_ms - subscriber.sent_ms < state.interval_ms ->
        wait_ms = state.interval_ms - (now_ms - subscriber.sent_ms)
        timer = Process.send_after(self(), {:deliver, key}, wait_ms)
        put_in(state.subscribers[key].timer, timer)

      true ->
        {jpeg, state} = jpeg(state, stream)
        if jpeg, do: send(pid, {:vision_preview, stream, jpeg})

        put_in(state.subscribers[key], %{
          subscriber
          | sequence: latest.sequence,
            awaiting_ack: jpeg != nil,
            sent_ms: if(jpeg, do: now_ms, else: subscriber.sent_ms)
        })
    end
  end

  defp jpeg(
         %{latest: %{depth: %{sequence: sequence}}, encoded_depth: {sequence, jpeg}} = state,
         :depth
       ),
       do: {jpeg, state}

  defp jpeg(state, :depth) do
    %{sequence: sequence, frame: pair} = state.latest.depth

    case encode_depth_safely(state, pair) do
      {:ok, jpeg} ->
        {jpeg, %{state | encoded_depth: {sequence, jpeg}, depth_failure_logged: false}}

      {:error, reason} ->
        unless state.depth_failure_logged,
          do: Logger.error("#{__MODULE__} cannot encode the depth preview: #{reason}")

        {nil, %{state | encoded_depth: {sequence, nil}, depth_failure_logged: true}}
    end
  end

  # Encoded on send: a grey frame costs an encode, and most are replaced unsent.
  defp jpeg(state, stream) do
    case Frame.to_jpeg(state.latest[stream].frame) do
      {:ok, jpeg} -> {jpeg, state}
      {:error, _reason} -> {nil, state}
    end
  end

  defp valid_option?(:max_hz, value), do: is_integer(value) and value in 1..30
  defp valid_option?(:depth_range_m, value), do: is_number(value) and value >= 0 and value <= 50
  defp valid_option?(_key, _value), do: false

  defp put_option(state, :max_hz, max_hz),
    do: %{state | max_hz: max_hz, interval_ms: div(1_000, max_hz)}

  defp put_option(state, :depth_range_m, range_m), do: %{state | depth_range_m: range_m * 1.0}

  defp encode_depth_safely(state, pair) do
    encode = state.depth_encoder || (&encode_depth(&1, state.depth_range_m))

    case encode.(pair) do
      jpeg when is_binary(jpeg) -> {:ok, jpeg}
      other -> {:error, inspect(other)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
