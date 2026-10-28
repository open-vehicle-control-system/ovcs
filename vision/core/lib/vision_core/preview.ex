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
  Pairs without a `depth_m` map are skipped, and so is a depth map
  that fails to encode, with one error logged until an encode succeeds.

  Started last in `VisionCore.Supervisor`; without a `:stereo`
  component it runs with nothing to preview.

  ## Options

    * `:config` — the active `VisionCore.Config` (required).
    * `:max_hz` (`5`) — frames per second per subscriber.
    * `:depth_range_m` (`10.0`) — the distance the colour map spans,
      from red at the camera to blue at this range.
    * `:depth_encoder` — `(VisionCore.Stereo.Pair.t() -> jpeg)`,
      replacing `encode_depth/2`.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.Pair
  alias VisionCore.Stereo.Sources

  @streams [:left, :right, :depth]
  @default_max_hz 5
  @default_depth_range_m 10.0
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
  The depth map of `pair` as a colour JPEG: near is red, `range_m` and
  beyond is blue, pixels without depth are black.
  """
  @spec encode_depth(Pair.t(), float()) :: binary()
  def encode_depth(%Pair{depth_m: depth_m}, range_m \\ @default_depth_range_m) do
    no_depth = Evision.compare(depth_m, 0.0, Evision.Constant.cv_CMP_LE())

    near_is_bright =
      depth_m
      |> Evision.min(range_m)
      |> Evision.convertScaleAbs(alpha: -255.0 / range_m, beta: 255.0)

    colourised =
      Evision.applyColorMap(src: near_is_bright, colormap: Evision.Constant.cv_COLORMAP_TURBO())

    Evision.imencode(".jpg", Evision.Mat.setTo(colourised, 0, no_depth),
      params: [Evision.Constant.cv_IMWRITE_JPEG_QUALITY(), @jpeg_quality]
    )
  end

  @impl GenServer
  def init(opts) do
    sources = opts |> Keyword.fetch!(:config) |> Sources.from_config()
    depth_range_m = Keyword.get(opts, :depth_range_m, @default_depth_range_m)

    {:ok,
     %{
       interval_ms: div(1_000, Keyword.get(opts, :max_hz, @default_max_hz)),
       depth_encoder:
         Keyword.get(opts, :depth_encoder, fn pair -> encode_depth(pair, depth_range_m) end),
       monitors: Sources.register(sources),
       latest: Map.new(@streams, &{&1, %{sequence: 0, frame: nil}}),
       encoded_depth: {0, nil},
       depth_failure_logged: false,
       subscribers: %{}
     }}
  end

  @impl GenServer
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
  def handle_cast({:camera_frame, %Frame{label: label, jpeg: jpeg}}, state)
      when label in ["left", "right"],
      do: {:noreply, store_frame(state, String.to_existing_atom(label), jpeg)}

  def handle_cast({:stereo_pair, %Pair{depth_m: nil}}, state), do: {:noreply, state}

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

    case encode_depth_safely(state.depth_encoder, pair) do
      {:ok, jpeg} ->
        {jpeg, %{state | encoded_depth: {sequence, jpeg}, depth_failure_logged: false}}

      {:error, reason} ->
        unless state.depth_failure_logged,
          do: Logger.error("#{__MODULE__} cannot encode the depth preview: #{reason}")

        {nil, %{state | encoded_depth: {sequence, nil}, depth_failure_logged: true}}
    end
  end

  defp jpeg(state, stream), do: {state.latest[stream].frame, state}

  defp encode_depth_safely(depth_encoder, pair) do
    case depth_encoder.(pair) do
      jpeg when is_binary(jpeg) -> {:ok, jpeg}
      other -> {:error, inspect(other)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
