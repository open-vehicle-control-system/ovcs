defmodule RPLidar.UART do
  @moduledoc """
  SLAMTEC RPLIDAR driver over a USB serial adapter, for the C1 and the
  other models speaking the same protocol. Implements
  `OvcsDrivers.Lidar`: listeners receive
  `{:lidar_scan, %OvcsDrivers.Lidar.Scan{}}` casts, one per revolution.

  The motor runs while the serial adapter's DTR line is low, which the
  driver sets when it opens the port. On `enable/0` it stops any scan
  in progress, reads the health and the device info (logged), then
  starts a standard scan. Each measurement
  is a 5-byte node: a start-of-revolution flag and its complement, a
  quality, the angle in 1/64 degree clockwise and the distance in 1/4
  mm. A node whose check bits do not hold is skipped one byte at a
  time until the stream lines up again. Health in error resets the
  sensor; a scan that stops delivering is restarted.

  ## Options

    * `:serial_number` or `:device` — the adapter (see
      `OvcsDrivers.Serial`)
    * `:speed` — baud rate (460800, the C1's)
    * `:range` — `{min, max}` metres the sensor measures
      (`{0.05, 12.0}`, the C1M1's)
  """
  @behaviour OvcsDrivers.Lidar

  use GenServer
  import Bitwise
  require Logger

  alias OvcsDrivers.Lidar.Scan

  @stop <<0xA5, 0x25>>
  @reset <<0xA5, 0x40>>
  @scan <<0xA5, 0x20>>
  @get_info <<0xA5, 0x50>>
  @get_health <<0xA5, 0x52>>

  @health_type 0x06
  @info_type 0x04
  @scan_type 0x81

  # The sensor needs a moment after STOP before it takes a request, and
  # seconds after RESET.
  @after_stop_ms 20
  @after_reset_ms 2_000
  @response_timeout_ms 1_000
  @stall_ms 2_000
  @retry_ms 5_000
  # The first measurements follow the scan request once the motor is up
  # to speed, about three seconds on the C1.
  @spin_up_ms 8_000
  # A revolution with fewer points is a partial one, at start-up.
  @min_points 50

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OvcsDrivers.Lidar
  def register_listener(pid), do: GenServer.cast(__MODULE__, {:register_listener, pid})

  @impl OvcsDrivers.Lidar
  def enable, do: GenServer.cast(__MODULE__, :enable)

  @impl true
  def init(opts) do
    {:ok, uart} = Circuits.UART.start_link()

    {:ok,
     %{
       opts: opts,
       uart: uart,
       connected?: false,
       range: Keyword.get(opts, :range, {0.05, 12.0}),
       listeners: [],
       mode: :idle,
       buffer: <<>>,
       points: [],
       started_at: nil,
       last_node_at: nil
     }}
  end

  @impl true
  def handle_cast({:register_listener, pid}, state),
    do: {:noreply, %{state | listeners: Enum.uniq([pid | state.listeners])}}

  def handle_cast(:enable, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info(:request_health, state) do
    send_request(state, @get_health)
    Process.send_after(self(), {:response_timeout, :health}, @response_timeout_ms)
    {:noreply, %{state | mode: {:awaiting, :health}, buffer: <<>>}}
  end

  def handle_info({:response_timeout, awaited}, %{mode: {:awaiting, awaited}} = state) do
    Logger.warning("#{__MODULE__}: no #{awaited} response, restarting")
    {:noreply, restart(state)}
  end

  def handle_info({:response_timeout, _}, state), do: {:noreply, state}

  def handle_info(:watchdog, %{mode: :scanning} = state) do
    Process.send_after(self(), :watchdog, @stall_ms)

    if now_ms() - (state.last_node_at || 0) > @stall_ms do
      Logger.warning("#{__MODULE__}: no scan data for #{@stall_ms} ms, restarting")
      {:noreply, restart(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:watchdog, state), do: {:noreply, state}

  def handle_info({:circuits_uart, _device, {:error, reason}}, state) do
    Logger.error("#{__MODULE__}: serial error #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _device, data}, state) when is_binary(data),
    do: {:noreply, receive_data(%{state | buffer: state.buffer <> data})}

  def handle_info(_message, state), do: {:noreply, state}

  # ── protocol ─────────────────────────────────────────────────

  # A missing adapter is retried rather than crashing the bridge's other
  # components with it.
  defp connect(%{connected?: true} = state), do: restart(state)

  defp connect(state) do
    speed = Keyword.get(state.opts, :speed, 460_800)

    with {:ok, device} <- OvcsDrivers.Serial.device(state.opts),
         :ok <- Circuits.UART.open(state.uart, device, speed: speed, active: true),
         # DTR low runs the motor; opening the port raises it.
         :ok <- Circuits.UART.set_dtr(state.uart, false) do
      Logger.info("#{__MODULE__} on /dev/#{device} at #{speed} baud")
      restart(%{state | connected?: true})
    else
      error ->
        Logger.warning("#{__MODULE__}: #{inspect(error)}; retrying in #{@retry_ms} ms")
        Process.send_after(self(), :connect, @retry_ms)
        state
    end
  end

  defp restart(state) do
    send_request(state, @stop)
    Process.send_after(self(), :request_health, @after_stop_ms)
    %{state | mode: :idle, buffer: <<>>, points: [], started_at: nil}
  end

  defp receive_data(%{mode: :idle} = state), do: %{state | buffer: <<>>}

  defp receive_data(%{mode: {:awaiting, :health}} = state) do
    case parse_response(state.buffer, @health_type, 3) do
      {:ok, <<status, error_code::little-16>>, _rest} -> health(state, status, error_code)
      :more -> state
    end
  end

  defp receive_data(%{mode: {:awaiting, :info}} = state) do
    case parse_response(state.buffer, @info_type, 20) do
      {:ok, <<model, minor, major, hardware, serial::binary-size(16)>>, _rest} ->
        Logger.info(
          "#{__MODULE__}: model 0x#{Integer.to_string(model, 16)}, firmware #{major}.#{minor}, " <>
            "hardware #{hardware}, serial #{Base.encode16(serial)}"
        )

        send_request(state, @scan)
        %{state | mode: {:awaiting, :scan}, buffer: <<>>}

      :more ->
        state
    end
  end

  defp receive_data(%{mode: {:awaiting, :scan}} = state) do
    case parse_response(state.buffer, @scan_type, 0) do
      {:ok, <<>>, rest} ->
        Process.send_after(self(), :watchdog, @stall_ms)

        receive_data(%{
          state
          | mode: :scanning,
            buffer: rest,
            last_node_at: now_ms() + @spin_up_ms - @stall_ms
        })

      :more ->
        state
    end
  end

  defp receive_data(%{mode: :scanning} = state) do
    {nodes, rest} = parse_nodes(state.buffer)
    now = System.system_time(:nanosecond)
    state = Enum.reduce(nodes, state, &add_node(&1, &2, now))
    %{state | buffer: rest, last_node_at: if(nodes == [], do: state.last_node_at, else: now_ms())}
  end

  defp health(state, 0, _error_code) do
    send_request(state, @get_info)
    Process.send_after(self(), {:response_timeout, :info}, @response_timeout_ms)
    %{state | mode: {:awaiting, :info}, buffer: <<>>}
  end

  defp health(state, 1, error_code) do
    Logger.warning("#{__MODULE__}: health warning, code #{error_code}")
    health(state, 0, error_code)
  end

  defp health(state, _status, error_code) do
    Logger.error("#{__MODULE__}: health error, code #{error_code}; resetting the sensor")
    send_request(state, @reset)
    Process.send_after(self(), :request_health, @after_reset_ms)
    %{state | mode: :idle, buffer: <<>>}
  end

  defp add_node({start?, _, _, _} = node, %{points: points} = state, now)
       when start? and length(points) >= @min_points do
    emit(state, now)
    add_node(node, %{state | points: [], started_at: nil}, now)
  end

  defp add_node({start?, _, _, _}, %{started_at: nil} = state, _now) when not start?,
    do: state

  defp add_node({_start?, angle, distance, quality}, state, now) do
    %{
      state
      | points: [{angle, distance, quality} | state.points],
        started_at: state.started_at || now
    }
  end

  defp emit(state, now) do
    scan = %Scan{
      points: Enum.reverse(state.points),
      started_at: state.started_at,
      duration_ns: now - state.started_at,
      range: state.range
    }

    Enum.each(state.listeners, &GenServer.cast(&1, {:lidar_scan, scan}))
  end

  defp send_request(state, request), do: Circuits.UART.write(state.uart, request)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ── wire format ──────────────────────────────────────────────

  @doc """
  The payload of the response of `type` at the head of `buffer`, of
  `length` bytes (0 for a scan, whose nodes follow), and the bytes
  after it; `:more` until all of it has arrived. Bytes before the
  response's descriptor are skipped.
  """
  def parse_response(buffer, type, length) do
    case :binary.match(buffer, <<0xA5, 0x5A>>) do
      {at, 2} ->
        case binary_part(buffer, at, byte_size(buffer) - at) do
          <<0xA5, 0x5A, _length_and_mode::little-32, ^type, payload::binary-size(length),
            rest::binary>> ->
            {:ok, payload, rest}

          _ ->
            :more
        end

      :nomatch ->
        :more
    end
  end

  @doc """
  The standard-scan nodes at the head of `buffer`, as `{start?, angle,
  distance, quality}` (angle in radians anticlockwise, distance in
  metres, 0.0 without a return), and the bytes left over. A node whose
  check bits do not hold is skipped a byte at a time.
  """
  def parse_nodes(buffer), do: parse_nodes(buffer, [])

  defp parse_nodes(<<b0, b1, b2, distance_q2::little-16, rest::binary>> = buffer, acc) do
    start = b0 &&& 1
    not_start = b0 >>> 1 &&& 1

    if start != not_start and (b1 &&& 1) == 1 do
      angle_q6 = b1 >>> 1 ||| b2 <<< 7
      node = {start == 1, anticlockwise(angle_q6 / 64), distance_q2 / 4000, b0 >>> 2}
      parse_nodes(rest, [node | acc])
    else
      <<_, resync::binary>> = buffer
      parse_nodes(resync, acc)
    end
  end

  defp parse_nodes(rest, acc), do: {Enum.reverse(acc), rest}

  # The sensor measures clockwise seen from above; ROS anticlockwise.
  defp anticlockwise(degrees_clockwise) do
    degrees = 360 - degrees_clockwise
    degrees = if degrees >= 360, do: degrees - 360, else: degrees
    degrees * :math.pi() / 180
  end
end
