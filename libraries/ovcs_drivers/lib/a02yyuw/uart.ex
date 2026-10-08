defmodule A02YYUW.UART do
  @moduledoc """
  DFRobot A02YYUW waterproof ultrasonic rangefinder over a serial
  adapter. Implements `OvcsDrivers.Rangefinder`: listeners receive
  `{:range_sample, %OvcsDrivers.Rangefinder.Sample{}}` casts, about ten
  a second.

  With its RX line left high the sensor sends a filtered distance every
  100 ms at 9600 baud as a 4-byte frame: `0xFF`, the distance in mm
  (big-endian), and a checksum, the low byte of the sum of the other
  three. Bytes that do not form a valid frame are skipped one at a
  time. The sensor sends 0 when no echo came back, reported as
  `:beyond_range`: nothing it can detect is in front of it.

  ## Options

    * `:name` (required) — the server's registered name; one per sensor
    * `:serial_number` or `:device` — the adapter (see
      `OvcsDrivers.Serial`)
    * `:range` — `{min, max}` metres (`{0.03, 4.5}`, the datasheet's)
    * `:field_of_view` — the beam's full angle in radians (60°)
  """
  @behaviour OvcsDrivers.Rangefinder

  use GenServer
  require Logger

  alias OvcsDrivers.Rangefinder.Sample

  @retry_ms 5_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @impl OvcsDrivers.Rangefinder
  def register_listener(server, pid), do: GenServer.cast(server, {:register_listener, pid})

  @impl true
  def init(opts) do
    {:ok, uart} = Circuits.UART.start_link()
    send(self(), :connect)

    {:ok,
     %{
       opts: opts,
       uart: uart,
       listeners: [],
       buffer: <<>>,
       range: Keyword.get(opts, :range, {0.03, 4.5}),
       field_of_view: Keyword.get(opts, :field_of_view, 60 * :math.pi() / 180)
     }}
  end

  @impl true
  def handle_cast({:register_listener, pid}, state),
    do: {:noreply, %{state | listeners: Enum.uniq([pid | state.listeners])}}

  # A missing adapter is retried rather than crashing the bridge's other
  # components with it.
  @impl true
  def handle_info(:connect, state) do
    with {:ok, device} <- OvcsDrivers.Serial.device(state.opts),
         :ok <- Circuits.UART.open(state.uart, device, speed: 9600, active: true) do
      Logger.info("#{__MODULE__}[#{inspect(state.opts[:name])}] on /dev/#{device}")
    else
      error ->
        Logger.warning(
          "#{__MODULE__}[#{inspect(state.opts[:name])}]: #{inspect(error)}; retrying in #{@retry_ms} ms"
        )

        Process.send_after(self(), :connect, @retry_ms)
    end

    {:noreply, state}
  end

  def handle_info({:circuits_uart, _device, data}, state) when is_binary(data) do
    {distances, rest} = parse_frames(state.buffer <> data)
    now = System.system_time(:nanosecond)

    for millimetres <- distances do
      sample = %Sample{
        distance: classify(millimetres / 1000, state.range),
        range: state.range,
        field_of_view: state.field_of_view,
        measured_at: now
      }

      Enum.each(state.listeners, &GenServer.cast(&1, {:range_sample, sample}))
    end

    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({:circuits_uart, _device, {:error, reason}}, state) do
    Logger.error("#{__MODULE__}: serial error #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp classify(metres, _range) when metres == 0, do: :beyond_range
  defp classify(metres, {min, _max}) when metres < min, do: :below_range
  defp classify(metres, {_min, max}) when metres > max, do: :beyond_range
  defp classify(metres, _range), do: metres

  @doc """
  The distances in mm of the valid frames in `buffer`, and the bytes
  left over. Pure.
  """
  def parse_frames(buffer), do: parse_frames(buffer, [])

  defp parse_frames(<<0xFF, high, low, sum, rest::binary>> = buffer, acc) do
    if rem(0xFF + high + low, 256) == sum,
      do: parse_frames(rest, [high * 256 + low | acc]),
      else: skip(buffer, acc)
  end

  defp parse_frames(<<0xFF, _::binary>> = partial, acc) when byte_size(partial) < 4,
    do: {Enum.reverse(acc), partial}

  defp parse_frames(<<>>, acc), do: {Enum.reverse(acc), <<>>}
  defp parse_frames(buffer, acc), do: skip(buffer, acc)

  defp skip(<<_, rest::binary>>, acc), do: parse_frames(rest, acc)
end
