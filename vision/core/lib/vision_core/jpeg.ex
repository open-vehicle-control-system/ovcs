defmodule VisionCore.Jpeg do
  @moduledoc """
  JPEG through the `jpeg_codec` Port: encodes grey frames and rectified
  images, colours and encodes depth previews, and decodes JPEG camera
  frames to grey.
  Requests are served one at a time.

  The binary is `priv/jpeg_codec`, or `config :vision_core,
  :jpeg_codec_path`. The Port opens on the first request and reopens
  after it exits. A request without a reply within `:timeout_ms`
  (`5000`) closes the Port, so its late reply cannot answer the next one.
  """
  use GenServer
  require Logger

  @default_timeout_ms 5_000
  @encode 0
  @decode 1
  @depth 2

  @doc "Starts the codec server; see the module doc for `opts`."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `pixels` as a JPEG: `width` x `height`, row-major, with 1 (grey) or 3
  (RGB) `channels`.
  """
  @spec encode(binary(), pos_integer(), pos_integer(), 1 | 3, 1..100) ::
          {:ok, binary()} | {:error, term()}
  def encode(pixels, width, height, channels, quality \\ 80)
      when channels in [1, 3] and byte_size(pixels) == width * height * channels do
    call(<<@encode, width::little-16, height::little-16, channels, quality, pixels::binary>>)
  end

  @doc "A `u8` `{height, width}` or `{height, width, 3}` tensor as a JPEG."
  @spec encode_tensor(Nx.Tensor.t(), 1..100) :: {:ok, binary()} | {:error, term()}
  def encode_tensor(%Nx.Tensor{} = image, quality \\ 80) do
    case Nx.shape(image) do
      {height, width} -> encode(Nx.to_binary(image), width, height, 1, quality)
      {height, width, 3} -> encode(Nx.to_binary(image), width, height, 3, quality)
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
          1..100
        ) ::
          {:ok, binary()} | {:error, term()}
  def encode_depth(depth_mm, width, height, near_mm, far_mm, quality \\ 80)
      when byte_size(depth_mm) == width * height * 2 do
    call(
      <<@depth, width::little-16, height::little-16, quality, near_mm::little-16,
        min(far_mm, 65_535)::little-16, depth_mm::binary>>
    )
  end

  @doc "A JPEG's luma: `{width, height, pixels}`, one byte a pixel, row-major."
  @spec decode_grey(binary()) ::
          {:ok, {pos_integer(), pos_integer(), binary()}} | {:error, term()}
  def decode_grey(jpeg) when is_binary(jpeg) do
    case call(<<@decode, jpeg::binary>>) do
      {:ok, <<width::little-16, height::little-16, pixels::binary>>} ->
        {:ok, {width, height, pixels}}

      {:ok, _malformed} ->
        {:error, :bad_reply}

      {:error, _reason} = error ->
        error
    end
  end

  # The server bounds each request by its own timeout.
  defp call(request), do: GenServer.call(__MODULE__, {:request, request}, :infinity)

  @impl GenServer
  def init(opts),
    do: {:ok, %{port: nil, timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)}}

  @impl GenServer
  def handle_call({:request, request}, _from, state) do
    case ensure_port(state) do
      {:ok, %{port: port} = state} ->
        Port.command(port, request)

        receive do
          {^port, {:data, <<>>}} ->
            {:reply, {:error, :bad_request}, state}

          {^port, {:data, reply}} ->
            {:reply, {:ok, reply}, state}

          {^port, {:exit_status, status}} ->
            {:reply, {:error, {:exited, status}}, %{state | port: nil}}
        after
          state.timeout_ms ->
            Port.close(port)
            {:reply, {:error, :timeout}, %{state | port: nil}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("#{__MODULE__}: jpeg_codec exited with #{status}")
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_port(%{port: nil} = state) do
    path = executable()

    if File.exists?(path) do
      port = Port.open({:spawn_executable, path}, [:binary, {:packet, 4}, :exit_status])
      {:ok, %{state | port: port}}
    else
      {:error, {:no_encoder, path}}
    end
  end

  defp ensure_port(state), do: {:ok, state}

  defp executable do
    Application.get_env(:vision_core, :jpeg_codec_path) ||
      Path.join(List.to_string(:code.priv_dir(:vision_core)), "jpeg_codec")
  end
end
