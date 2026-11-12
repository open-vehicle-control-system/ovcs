defmodule VisionCore.Preview do
  @moduledoc """
  Live JPEG previews of the vision unit for the dashboard: the stereo
  unit's `:left` and `:right` camera frames as captured and its `:depth`
  map colourised, and one stream per camera of its own
  (`VisionCore.Camera.Unit`), named as the camera is, from its frames.

  A subscriber receives `{:vision_preview, stream, jpeg}` and calls
  `ack/1` once it has handled the frame. Each subscriber has at most one
  unacknowledged frame and receives at most `:max_hz` frames a second;
  frames arriving in between replace each other, so a slow subscriber
  gets the latest frame, never a backlog.

  The depth map is colourised and encoded only when a depth subscriber
  is due a frame, once per pair whatever the number of subscribers.
  Pairs without a depth image are skipped, and so is a depth map
  that fails to encode, with one error logged until an encode succeeds.

  `:max_hz` and `:depth_range_m` are the vehicle's `VisionCore.Config`
  `:preview` options and change while running with `set_options/1`; the
  dashboard sets the depth range through `VisionApiWeb.PreviewChannel`.
  The depth range is the unit's, shared by every dashboard: a change is
  sent to each depth subscriber as `{:vision_preview_options,
  %{depth_range_m: metres}}`.

  A camera's frame is held until it is replaced and encoded only when a
  subscriber is due it, at the preview's rate, so a frame of several
  megapixels costs an encode a preview, not one per frame.

  Each stream encodes in a task of its own, one frame at a time, so a
  slow stream delays only itself. A frame that comes during an encode
  waits, replaced by any newer one; the encoded frame still goes to the
  subscribers due one, and the waiting frame is encoded when one is due
  again. Each stream holds its newest frame and at most one in its
  encode.

  Started after the components in `VisionCore.Supervisor`; without a
  `:stereo` or `:camera` component it runs with nothing to preview.

  ## Options

    * `:config` — the active `VisionCore.Config` (required).
    * `:max_hz` (`10`) — frames per second per subscriber.
    * `:outputs` (`[]`) — the output each camera of its own's stream
      shows, by camera name (`hq: :view`), its default output for a
      camera not listed (`VisionCore.Camera.Unit.output_key/3`). An
      output the camera does not have is logged, and its default shown.
    * `:depth_range_m` (`0.0`) — the distance coloured blue; 0 colours
      blue only what is infinitely far, so the colours stay put from one
      frame to the next. Red is the nearest measured depths.
    * `:jpeg_codec` (`VisionCore.Jpeg`) — the `VisionCore.Jpeg` instance
      the previews are encoded on. `VisionCore.Application` gives
      `VisionCore.Jpeg.Export`, apart from the pipeline's.
    * `:depth_encoder` — `(VisionCore.Stereo.Pair.t() -> jpeg)`,
      replacing `encode_depth/3`.
    * `:frame_encoder` — `(VisionCore.Camera.Frame.t() -> {:ok, jpeg} |
      {:error, reason})`, replacing `VisionCore.Camera.Frame.to_jpeg/2`.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @stereo_streams [:left, :right, :depth]
  @default_max_hz 10
  @default_depth_range_m 0.0

  @jpeg_quality 80

  @typedoc "`:left`, `:right`, `:depth` or the name of a camera of its own."
  @type stream :: atom()

  @doc "Starts the preview server; see the module doc for the options."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Sends the caller `stream`'s frames as `{:vision_preview, stream, jpeg}`
  until it exits; `{:error, :unknown_stream}` for a stream the unit has
  no camera for.
  """
  @spec subscribe(stream()) :: :ok | {:error, :unknown_stream}
  def subscribe(stream) when is_atom(stream),
    do: GenServer.call(__MODULE__, {:subscribe, self(), stream})

  @doc "Tells the server the caller has handled its last `stream` frame."
  @spec ack(stream()) :: :ok
  def ack(stream) when is_atom(stream), do: GenServer.cast(__MODULE__, {:ack, self(), stream})

  @doc """
  The depth of `pair` as a colour JPEG, by 1/depth: the nearest measured
  depths are red, `range_m` and beyond blue (with 0, infinitely far),
  pixels without depth black. Coloured and encoded on the CPU by the
  `VisionCore.Jpeg` instance `jpeg_codec`, from the millimetre depth image.
  """
  @spec encode_depth(Pair.t(), float(), GenServer.server()) :: binary() | {:error, term()}
  def encode_depth(
        %Pair{depth: depth} = pair,
        range_m \\ @default_depth_range_m,
        jpeg_codec \\ VisionCore.Jpeg
      )
      when is_binary(depth) do
    {width, height} = Pair.size(pair)
    far_mm = round(range_m * 1_000)
    options = [quality: @jpeg_quality, codec: jpeg_codec]

    case VisionCore.Jpeg.encode_depth(depth, width, height, 0, far_mm, options) do
      {:ok, jpeg} -> jpeg
      {:error, _reason} = error -> error
    end
  end

  @doc "The settings in force."
  def options, do: GenServer.call(__MODULE__, :options)

  @doc "Changes settings, or says why it cannot; none change on a refusal."
  @spec set_options(keyword()) :: {:ok, map()} | {:error, String.t()}
  def set_options(options), do: GenServer.call(__MODULE__, {:set_options, options})

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    cameras = Camera.Unit.cameras(config)

    outputs = Keyword.get(opts, :outputs, [])

    for {_output, key} <- StereoSupervisor.outputs(config), do: :ok = Outputs.subscribe(key)

    for {name, _driver, _server} <- cameras,
        key = camera_key(config, name, outputs[name]),
        do: :ok = Outputs.subscribe(key)

    streams = @stereo_streams ++ for {name, _driver, _server} <- cameras, do: name

    max_hz = Keyword.get(opts, :max_hz, @default_max_hz)
    jpeg_codec = Keyword.get(opts, :jpeg_codec, VisionCore.Jpeg)

    {:ok,
     %{
       max_hz: max_hz,
       depth_range_m: Keyword.get(opts, :depth_range_m, @default_depth_range_m) * 1.0,
       interval_ms: div(1_000, max_hz),
       jpeg_codec: jpeg_codec,
       depth_encoder: Keyword.get(opts, :depth_encoder),
       frame_encoder: Keyword.get(opts, :frame_encoder, &Frame.to_jpeg(&1, jpeg_codec)),
       streams: streams,
       latest: Map.new(streams, &{&1, %{sequence: 0, frame: nil}}),
       encoded: Map.new(streams, &{&1, {0, nil}}),
       encoding: %{},
       depth_failure_logged: false,
       subscribers: %{}
     }}
  end

  # `nil` for a camera whose outputs cannot be made, whose unit is down.
  defp camera_key(config, name, output) do
    case {Camera.Unit.output_key(config, name, output), Camera.Unit.output_key(config, name, nil)} do
      {nil, nil} ->
        nil

      {nil, default} ->
        Logger.error(
          "#{inspect(__MODULE__)}: camera #{name} has no output #{inspect(output)}; " <>
            "its stream shows its default output"
        )

        default

      {key, _default} ->
        key
    end
  end

  @impl GenServer
  def handle_call(:options, _from, state),
    do: {:reply, Map.take(state, [:max_hz, :depth_range_m]), state}

  def handle_call({:set_options, options}, _from, state) do
    case Enum.find(options, fn {key, value} -> not valid_option?(key, value) end) do
      nil ->
        state =
          Enum.reduce(options, state, fn {key, value}, state -> put_option(state, key, value) end)

        state =
          if Keyword.has_key?(options, :depth_range_m),
            do: state |> announce_depth_range() |> recolour_depth(),
            else: state

        {:reply, {:ok, Map.take(state, [:max_hz, :depth_range_m])}, state}

      {key, value} ->
        {:reply, {:error, "#{key}: invalid value #{inspect(value)}"}, state}
    end
  end

  def handle_call({:subscribe, _pid, stream}, _from, state)
      when not is_map_key(state.latest, stream),
      do: {:reply, {:error, :unknown_stream}, state}

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
  def handle_cast({:camera_frame, %Frame{label: label} = frame}, state) do
    case Enum.find(state.streams, &(Atom.to_string(&1) == label and &1 != :depth)) do
      nil -> {:noreply, state}
      stream -> {:noreply, store_frame(state, stream, frame)}
    end
  end

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

  def handle_info({reference, result}, state) when is_map_key(state.encoding, reference) do
    Process.demonitor(reference, [:flush])
    {{stream, sequence}, encoding} = Map.pop(state.encoding, reference)
    {:noreply, encoded(%{state | encoding: encoding}, stream, sequence, result)}
  end

  def handle_info({:DOWN, monitor_reference, :process, _pid, _reason}, state) do
    subscribers =
      Map.reject(state.subscribers, fn {_key, subscriber} ->
        subscriber.monitor == monitor_reference
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp store_frame(state, stream, frame) do
    state =
      update_in(state.latest[stream], fn latest ->
        %{sequence: latest.sequence + 1, frame: frame}
      end)

    state
    |> subscriber_keys(stream)
    |> Enum.reduce(state, &deliver(&2, &1))
  end

  defp subscriber_keys(state, stream),
    do: state.subscribers |> Map.keys() |> Enum.filter(&match?({_pid, ^stream}, &1))

  defp deliver(state, {_pid, stream} = key) do
    subscriber = state.subscribers[key]
    latest = state.latest[stream]
    now_ms = System.monotonic_time(:millisecond)

    cond do
      is_nil(latest.frame) or latest.sequence <= subscriber.sequence or subscriber.awaiting_ack or
          subscriber.timer != nil ->
        state

      not interval_elapsed?(state, subscriber, now_ms) ->
        wait_ms = state.interval_ms - (now_ms - subscriber.sent_ms)
        timer = Process.send_after(self(), {:deliver, key}, wait_ms)
        put_in(state.subscribers[key].timer, timer)

      true ->
        # Each stream's latest frame is encoded once, however many subscribers it goes to.
        case state.encoded[stream] do
          {sequence, jpeg} when sequence == latest.sequence ->
            send_frame(state, key, sequence, jpeg, now_ms)

          _stale ->
            encode(state, stream)
        end
    end
  end

  defp interval_elapsed?(state, subscriber, now_ms),
    do: subscriber.sent_ms == nil or now_ms - subscriber.sent_ms >= state.interval_ms

  # A `nil` jpeg, a frame that failed to encode, is skipped.
  defp send_frame(state, {pid, stream} = key, sequence, jpeg, now_ms) do
    if jpeg, do: send(pid, {:vision_preview, stream, jpeg})

    update_in(state.subscribers[key], fn subscriber ->
      %{
        subscriber
        | sequence: sequence,
          awaiting_ack: jpeg != nil,
          sent_ms: if(jpeg, do: now_ms, else: subscriber.sent_ms)
      }
    end)
  end

  # Encoded on send: a grey frame costs an encode, and most are replaced unsent.
  defp encode(state, stream) do
    if Enum.any?(state.encoding, &match?({_reference, {^stream, _sequence}}, &1)) do
      state
    else
      %{sequence: sequence, frame: frame} = state.latest[stream]
      encoder = encoder(state, stream)
      task = Task.async(fn -> encode_safely(encoder, frame) end)
      put_in(state.encoding[task.ref], {stream, sequence})
    end
  end

  defp encoder(%{depth_encoder: nil, depth_range_m: range_m, jpeg_codec: jpeg_codec}, :depth),
    do: depth_encoder(&encode_depth(&1, range_m, jpeg_codec))

  defp encoder(state, :depth), do: depth_encoder(state.depth_encoder)
  defp encoder(state, _stream), do: state.frame_encoder

  defp depth_encoder(encode) do
    fn pair ->
      case encode.(pair) do
        jpeg when is_binary(jpeg) -> {:ok, jpeg}
        other -> {:error, inspect(other)}
      end
    end
  end

  defp encode_safely(encode, frame) do
    encode.(frame)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, Exception.format_exit(reason)}
  end

  # The encoded frame goes to each subscriber due one, though a newer frame may wait.
  defp encoded(state, stream, sequence, result) do
    {jpeg, state} = encode_result(state, stream, result)
    state = put_in(state.encoded[stream], {sequence, jpeg})
    now_ms = System.monotonic_time(:millisecond)

    state
    |> subscriber_keys(stream)
    |> Enum.reduce(state, fn key, state ->
      subscriber = state.subscribers[key]

      state =
        if sequence > subscriber.sequence and not subscriber.awaiting_ack and
             subscriber.timer == nil and interval_elapsed?(state, subscriber, now_ms),
           do: send_frame(state, key, sequence, jpeg, now_ms),
           else: state

      deliver(state, key)
    end)
  end

  defp encode_result(state, :depth, {:ok, jpeg}),
    do: {jpeg, %{state | depth_failure_logged: false}}

  defp encode_result(state, :depth, {:error, reason}) do
    unless state.depth_failure_logged,
      do: Logger.error("#{__MODULE__} cannot encode the depth preview: #{reason}")

    {nil, %{state | depth_failure_logged: true}}
  end

  defp encode_result(state, _stream, {:ok, jpeg}), do: {jpeg, state}
  defp encode_result(state, _stream, _error), do: {nil, state}

  # The depth range is the unit's, shared by every dashboard: each depth subscriber hears a new one.
  defp announce_depth_range(state) do
    for {pid, :depth} <- Map.keys(state.subscribers),
        do: send(pid, {:vision_preview_options, %{depth_range_m: state.depth_range_m}})

    state
  end

  # The latest depth map again, as a new frame, so it is coloured over the new range and sent again.
  defp recolour_depth(%{latest: %{depth: %{frame: nil}}} = state), do: state
  defp recolour_depth(state), do: store_frame(state, :depth, state.latest.depth.frame)

  defp valid_option?(:max_hz, value), do: is_integer(value) and value in 1..30
  defp valid_option?(:depth_range_m, value), do: is_number(value) and value >= 0 and value <= 50
  defp valid_option?(_key, _value), do: false

  defp put_option(state, :max_hz, max_hz),
    do: %{state | max_hz: max_hz, interval_ms: div(1_000, max_hz)}

  defp put_option(state, :depth_range_m, range_m), do: %{state | depth_range_m: range_m * 1.0}
end
