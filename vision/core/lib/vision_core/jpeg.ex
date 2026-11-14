defmodule VisionCore.Jpeg do
  @moduledoc """
  JPEG through a pool of `jpeg_codec` Ports: encodes grey frames and
  rectified images, colours and encodes depth previews, and decodes JPEG
  camera frames to grey.

  Each Port serves one request at a time. A request goes to any free
  Port, so a slow encode holds only its own Port; once all `:ports` are
  busy, requests wait in one queue, served in arrival order. A caller
  waits for its reply, so it has one request in the pool at a time:
  the queue is no longer than the number of callers, and a caller
  sending request after request waits its turn like the others,
  starving none.

  An encode that names its frame (`:frame`) is shared: requests for the
  same frame at the same quality, while one of them waits or encodes,
  are answered with its JPEG, and so is a request for the frame whose
  JPEG its stream holds, the latest each stream encoded. A failed encode
  answers each of its requests with its error and is not held.

  `VisionCore.Application` starts two instances: `VisionCore.Jpeg`, one
  Port on which the stereo pipeline decodes JPEG camera frames, and
  `VisionCore.Jpeg.Export`, the pool `VisionCore.Preview` and the
  exporters encode on, sized by the configuration's `:jpeg` options
  (`VisionCore.Config`), so that those encodes and the pipeline's
  decodes do not wait on each other. Each function runs on the instance
  its `:codec` option names, `VisionCore.Jpeg` by default.

  The binary is `priv/jpeg_codec`, or `config :vision_core,
  :jpeg_codec_path`. A Port opens when a request finds every open Port
  busy and fewer than `:ports` open. A Port that exits fails its own
  request only, and another opens for the next. A request without a
  reply within `:timeout_ms` of reaching its Port closes that Port, so
  its late reply cannot answer the next one, and kills its program if
  it does not exit (`VisionCore.PortProcess`). A program that cannot be
  run answers its request with `{:error, {:no_encoder, path, reason}}`.

  ## Options

    * `:name` (`VisionCore.Jpeg`) — the server's name, and its child id.
    * `:ports` (`3`) — the most Ports open at once, a positive integer.
    * `:timeout_ms` (`5000`) — how long a request may wait for its
      reply once on a Port.
  """
  use GenServer
  require Logger

  @default_ports 3
  @default_timeout_ms 5_000
  @default_quality 80
  @encode 0
  @decode 1
  @depth 2

  @typedoc """
  `:codec`, the instance a request runs on, an encode's `:quality`
  (`80`), and the `:frame` its pixels are of, `{stream, capture_ns}`,
  `stream` naming the frames of one camera output, such as `{label,
  output}`.
  """
  @type option ::
          {:codec, GenServer.server()} | {:quality, 1..100} | {:frame, {term(), integer()}}

  @doc """
  Starts the codec server; see the module doc for `opts`. Raises
  `ArgumentError` when `:ports` is not a positive integer.
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :ports, @default_ports) do
      ports when is_integer(ports) and ports > 0 ->
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

      ports ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :ports is a positive integer, got #{inspect(ports)}"
    end
  end

  @doc false
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc """
  `pixels` as a JPEG: `width` x `height`, row-major, with 1 (grey) or 3
  (RGB) `channels`. With `:frame`, the JPEG of a request for the same
  frame at the same quality, when there is one, whatever `pixels` holds.
  """
  @spec encode(binary(), pos_integer(), pos_integer(), 1 | 3, [option()]) ::
          {:ok, binary()} | {:error, term()}
  def encode(pixels, width, height, channels, options \\ [])
      when channels in [1, 3] and byte_size(pixels) == width * height * channels do
    call(
      options,
      [<<@encode, width::little-16, height::little-16, channels, quality(options)>>, pixels],
      shared_frame(options)
    )
  end

  @doc "A `u8` `{height, width}` or `{height, width, 3}` tensor as a JPEG."
  @spec encode_tensor(Nx.Tensor.t(), [option()]) :: {:ok, binary()} | {:error, term()}
  def encode_tensor(%Nx.Tensor{} = image, options \\ []) do
    case Nx.shape(image) do
      {height, width} -> encode(Nx.to_binary(image), width, height, 1, options)
      {height, width, 3} -> encode(Nx.to_binary(image), width, height, 3, options)
    end
  end

  @doc """
  `depth_mm`, a row-major u16 depth image in millimetres (0 where
  unmeasured), as a JPEG coloured with the turbo map by 1/depth, so near
  differences show: `near_mm` red, `far_mm` blue, no depth black. A
  `near_mm` of 0 is the 2nd percentile of the measured depths, a
  `far_mm` of 0 infinitely far.
  """
  @spec encode_depth(
          binary(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [option()]
        ) ::
          {:ok, binary()} | {:error, term()}
  def encode_depth(depth_mm, width, height, near_mm, far_mm, options \\ [])
      when byte_size(depth_mm) == width * height * 2 do
    call(
      options,
      <<@depth, width::little-16, height::little-16, quality(options), near_mm::little-16,
        min(far_mm, 65_535)::little-16, depth_mm::binary>>
    )
  end

  @doc "A JPEG's luma: `{width, height, pixels}`, one byte a pixel, row-major."
  @spec decode_grey(binary(), [{:codec, GenServer.server()}]) ::
          {:ok, {pos_integer(), pos_integer(), binary()}} | {:error, term()}
  def decode_grey(jpeg, options \\ []) when is_binary(jpeg) do
    case call(options, <<@decode, jpeg::binary>>) do
      {:ok, <<width::little-16, height::little-16, pixels::binary>>} ->
        {:ok, {width, height, pixels}}

      {:ok, _malformed} ->
        {:error, :bad_reply}

      {:error, _reason} = error ->
        error
    end
  end

  # The server bounds each request by its own timeout.
  defp call(options, request, shared_frame \\ nil),
    do:
      GenServer.call(
        Keyword.get(options, :codec, __MODULE__),
        {:request, request, shared_frame},
        :infinity
      )

  defp quality(options), do: Keyword.get(options, :quality, @default_quality)

  defp shared_frame(options) do
    case Keyword.fetch(options, :frame) do
      {:ok, {stream, capture_ns}} -> {stream, capture_ns, quality(options)}
      :error -> nil
    end
  end

  # `ports` maps each open Port to its request, `nil` while free; `waiting` holds the
  # requests no Port is free for, oldest first; `sharing` the callers of each shared
  # frame's request until it is answered; `finished` each stream's latest JPEG.
  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       size: Keyword.get(opts, :ports, @default_ports),
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       ports: %{},
       waiting: :queue.new(),
       sharing: %{},
       finished: %{}
     }}
  end

  @impl GenServer
  def handle_call({:request, request, nil}, from, state),
    do: {:noreply, dispatch(%{state | waiting: :queue.in({from, request}, state.waiting)})}

  def handle_call({:request, request, {stream, capture_ns, quality} = frame}, from, state) do
    case state do
      %{finished: %{^stream => {{^capture_ns, ^quality}, jpeg}}} ->
        {:reply, {:ok, jpeg}, state}

      %{sharing: %{^frame => callers}} ->
        {:noreply, put_in(state.sharing[frame], [from | callers])}

      _new_frame ->
        state = %{
          state
          | sharing: Map.put(state.sharing, frame, [from]),
            waiting: :queue.in({{:shared, frame}, request}, state.waiting)
        }

        {:noreply, dispatch(state)}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, reply}}, state) when is_map_key(state.ports, port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      %{from: from, timer: timer} ->
        Process.cancel_timer(timer)
        reply = if reply == <<>>, do: {:error, :bad_request}, else: {:ok, reply}
        {:noreply, state |> put_in([:ports, port], nil) |> answer(from, reply) |> dispatch()}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_map_key(state.ports, port) do
    Logger.warning("#{__MODULE__}: jpeg_codec exited with #{status}")
    {:noreply, state |> retire_port(port, {:error, {:exited, status}}) |> dispatch()}
  end

  def handle_info({:timeout, port, reference}, state) do
    case state.ports do
      %{^port => %{reference: ^reference}} ->
        close(port)
        {:noreply, state |> retire_port(port, {:error, :timeout}) |> dispatch()}

      _ports ->
        {:noreply, state}
    end
  end

  # Replies from a Port closed on a timeout come here, answering no one.
  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(state) do
    case :queue.out(state.waiting) do
      {:empty, _waiting} ->
        state

      {{:value, {from, request}}, waiting} ->
        case free_port(state) do
          {:ok, port} ->
            %{state | waiting: waiting} |> send_request(port, from, request) |> dispatch()

          :busy ->
            state

          {:error, _reason} = error ->
            %{state | waiting: waiting} |> answer(from, error) |> dispatch()
        end
    end
  end

  defp free_port(state) do
    case Enum.find(state.ports, fn {_port, request} -> request == nil end) do
      {port, nil} -> {:ok, port}
      nil when map_size(state.ports) < state.size -> open_port()
      nil -> :busy
    end
  end

  defp send_request(state, port, from, request) do
    Port.command(port, request)
    reference = make_ref()
    timer = Process.send_after(self(), {:timeout, port, reference}, state.timeout_ms)
    put_in(state.ports[port], %{from: from, reference: reference, timer: timer})
  rescue
    # The Port exited while free, its exit status not yet handled: the request takes another.
    ArgumentError ->
      %{
        state
        | ports: Map.delete(state.ports, port),
          waiting: :queue.in_r({from, request}, state.waiting)
      }
  end

  # Forgets `port`, answering its request, if any, with `reply`.
  defp retire_port(state, port, reply) do
    {request, ports} = Map.pop(state.ports, port)
    state = %{state | ports: ports}

    case request do
      %{from: from, timer: timer} ->
        Process.cancel_timer(timer)
        answer(state, from, reply)

      nil ->
        state
    end
  end

  defp answer(state, {:shared, {stream, capture_ns, quality} = frame}, reply) do
    {callers, sharing} = Map.pop!(state.sharing, frame)
    Enum.each(callers, &GenServer.reply(&1, reply))
    finished = hold_latest(state.finished, stream, {capture_ns, quality}, reply)
    %{state | sharing: sharing, finished: finished}
  end

  defp answer(state, from, reply) do
    GenServer.reply(from, reply)
    state
  end

  # A frame encoded after a newer one of its stream is not held.
  defp hold_latest(finished, stream, {capture_ns, _quality} = frame, {:ok, jpeg}) do
    case finished do
      %{^stream => {{newer_ns, _newer_quality}, _jpeg}} when newer_ns > capture_ns -> finished
      _older -> Map.put(finished, stream, {frame, jpeg})
    end
  end

  defp hold_latest(finished, _stream, _frame, {:error, _reason}), do: finished

  # A program that does not exit with its Port is killed; one already gone is left alone.
  defp close(port), do: VisionCore.PortProcess.close(port)

  defp open_port do
    path = executable()

    if File.exists?(path),
      do: {:ok, Port.open({:spawn_executable, path}, [:binary, {:packet, 4}, :exit_status])},
      else: {:error, {:no_encoder, path}}
  rescue
    # A program that cannot be run, or no room for another Port.
    error in [ErlangError, ArgumentError, SystemLimitError] ->
      {:error, {:no_encoder, executable(), error_reason(error)}}
  end

  defp error_reason(%ErlangError{original: reason}), do: reason
  defp error_reason(error), do: Exception.message(error)

  defp executable do
    Application.get_env(:vision_core, :jpeg_codec_path) ||
      Path.join(List.to_string(:code.priv_dir(:vision_core)), "jpeg_codec")
  end
end
