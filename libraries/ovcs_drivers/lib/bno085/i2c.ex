# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Readability.WithSingleClause
defmodule BNO085.I2C do
  @moduledoc """
  BNO085 driver over I²C using the SH-2 protocol. Implements the
  `OvcsDrivers.Imu` behaviour: listeners receive
  `{:imu_sample, %OvcsDrivers.Imu.Sample{}}` casts in SI units. Pure
  hardware concerns — Q-point scaling, register layouts, chip-ready
  gating all live here; framework-side translation lives in the
  consuming application.

  The orientation is the game rotation vector, fused from the gyroscope
  and the accelerometer alone: indoors, a magnetometer-corrected heading
  jumps tens of degrees near steel or a motor. The heading drifts slowly
  instead, relative to where the chip started.

  Options: `:report_interval_us` (20_000), `:poll_interval_ms` (5),
  `:max_packets_per_poll` (8), `:stream_timeout_ms` (500), and `:bus`
  ("i2c-1"). Each requested stream is watched independently, with
  bounded enable retries followed by a reset. A reset changes the
  samples' orientation `reference`; consumers must not join headings
  across it. Uncalibrated gyro reports are not enabled.

  Capture times include SH-2 signed base/rebase and report delay, anchored
  to the host poll time. Without an interrupt timestamp, polling and
  transport latency remain; these are estimates, not hardware clock sync.
  """
  @behaviour OvcsDrivers.Imu

  use GenServer
  import Bitwise
  require Logger

  alias OvcsDrivers.Imu.Sample

  @address 0x4A
  @product_id_request 0xF9
  @product_id_response 0xF8
  @set_feature_request 0xFD
  @timebase_reference_report 0xFB
  @accelerometer_report 0x01
  @calibrated_gyroscope_report 0x02
  @game_rotation_vector_report 0x08
  @uncalibrated_gyroscope_report 0x07
  @command_reponse 0xF1
  @reset_complete_response 0x01
  @shtp_command_channel 0x00
  @executable_channel 0x01
  @sensor_hub_control_channel 0x02
  @inport_sensor_reports_channel 0x03
  @accelerometer_scale 1.0 / (1 <<< 8)
  @gyroscope_scale 1.0 / (1 <<< 9)
  @quaternion_scale 1.0 / (1 <<< 14)
  @imu_sample_ids [
    @accelerometer_report,
    @calibrated_gyroscope_report,
    @game_rotation_vector_report
  ]
  @enable_verify_ms 500
  @max_enable_attempts 5
  @chip_ready_timeout_ms 5_000

  @impl GenServer
  def init(opts) do
    transport = Keyword.get(opts, :transport, Circuits.I2C)
    {:ok, i2c} = transport.open(Keyword.get(opts, :bus, "i2c-1"))
    state = new_state(i2c, opts)
    GenServer.cast(self(), :reset)
    Process.send_after(self(), :loop, state.poll_interval_ms)
    {:ok, state}
  end

  @doc false
  def new_state(i2c, opts) do
    %{
      i2c: i2c,
      transport: Keyword.get(opts, :transport, Circuits.I2C),
      report_interval_us: positive_option!(opts, :report_interval_us, 20_000),
      poll_interval_ms: positive_option!(opts, :poll_interval_ms, 5),
      max_packets_per_poll: positive_option!(opts, :max_packets_per_poll, 8),
      stream_timeout_ms: positive_option!(opts, :stream_timeout_ms, 500),
      listeners: [],
      chip_ready?: false,
      pending_enables: [],
      requested_enables: [],
      last_reports: %{},
      reference: make_ref(),
      enable_attempts: 0,
      verify_ref: nil,
      ready_ref: nil,
      channel_sequences: %{}
    }
  end

  defp positive_option!(opts, key, default) do
    option = Keyword.get(opts, key, default)
    if not is_integer(option) or option <= 0, do: raise(ArgumentError, "#{key} must be positive")
    option
  end

  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @inport_sensor_reports_channel
       )
       when report_id == @calibrated_gyroscope_report and bit_size(report_bytes) >= 10 * 8 do
    <<
      sequence_number::8,
      status::8,
      delay::8,
      calibrated_axis_x::little-signed-integer-size(16),
      calibrated_axis_y::little-signed-integer-size(16),
      calibrated_axis_z::little-signed-integer-size(16),
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       name: "calibrated_gyroscope",
       sequence_number: sequence_number,
       status: status,
       delay: delay,
       x: calibrated_axis_x,
       y: calibrated_axis_y,
       z: calibrated_axis_z
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @inport_sensor_reports_channel
       )
       when report_id == @uncalibrated_gyroscope_report and bit_size(report_bytes) >= 16 * 8 do
    <<
      sequence_number::8,
      status::8,
      delay::8,
      uncalibrated_axis_x::little-signed-integer-size(16),
      uncalibrated_axis_y::little-signed-integer-size(16),
      uncalibrated_axis_z::little-signed-integer-size(16),
      uncalibrated_bias_axis_x::little-signed-integer-size(16),
      uncalibrated_bias_axis_y::little-signed-integer-size(16),
      uncalibrated_bias_axis_z::little-signed-integer-size(16),
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       name: "uncalibrated_gyroscope",
       sequence_number: sequence_number,
       status: status,
       delay: delay,
       x: uncalibrated_axis_x,
       y: uncalibrated_axis_y,
       z: uncalibrated_axis_z,
       x_bias: uncalibrated_bias_axis_x,
       y_bias: uncalibrated_bias_axis_y,
       z_bias: uncalibrated_bias_axis_z
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @inport_sensor_reports_channel
       )
       when report_id == @game_rotation_vector_report and bit_size(report_bytes) >= 12 * 8 do
    # SH-2 game-rotation-vector report: header bytes + 4 little-endian
    # int16s, the quaternion components (i, j, k, real) in Q14.
    <<
      sequence_number::8,
      status::8,
      delay::8,
      quaternion_i::little-signed-integer-size(16),
      quaternion_j::little-signed-integer-size(16),
      quaternion_k::little-signed-integer-size(16),
      quaternion_real::little-signed-integer-size(16),
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       name: "game_rotation_vector",
       sequence_number: sequence_number,
       status: status,
       delay: delay,
       i: quaternion_i,
       j: quaternion_j,
       k: quaternion_k,
       real: quaternion_real
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @inport_sensor_reports_channel
       )
       when report_id in [@timebase_reference_report, 0xFA] and byte_size(report_bytes) >= 5 do
    <<
      base_delta::little-signed-integer-size(32),
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       base_delta: base_delta
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @inport_sensor_reports_channel
       )
       when report_id == @accelerometer_report and bit_size(report_bytes) >= 10 * 8 do
    <<
      sequence_number::8,
      status::8,
      delay::8,
      axis_x::little-signed-integer-size(16),
      axis_y::little-signed-integer-size(16),
      axis_z::little-signed-integer-size(16),
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       name: "accelerometer",
       sequence_number: sequence_number,
       status: status,
       delay: delay,
       x: axis_x,
       y: axis_y,
       z: axis_z
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @sensor_hub_control_channel
       )
       when report_id == @command_reponse and bit_size(report_bytes) >= 16 * 8 do
    <<
      sequence_number,
      command,
      command_sequence_number,
      response_sequence_number,
      _0::8,
      _1::8,
      _2::8,
      _3::8,
      _4::8,
      _5::8,
      _6::8,
      _7::8,
      _8::8,
      _9::8,
      _10::8,
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       sequence_number: sequence_number,
       command: command,
       command_sequence_number: command_sequence_number,
       response_sequence_number: response_sequence_number
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @sensor_hub_control_channel
       )
       when report_id == @product_id_response and byte_size(report_bytes) >= 16 do
    <<
      reset_cause,
      sw_version_major,
      sw_version_minor,
      sw_part_number::little-integer-size(32),
      sw_build_number::little-integer-size(32),
      sw_patch::little-integer-size(16),
      _0::8,
      _1::8,
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id,
       name: "product_id_response",
       reset_cause: reset_cause,
       part_number: sw_part_number,
       software_version: "#{sw_version_major}.#{sw_version_minor}.#{sw_patch}",
       build_number: sw_build_number
     }, rest}
  end

  defp parse_report(
         <<report_id::integer, report_data::binary>> = report_bytes,
         @executable_channel
       )
       when bit_size(report_bytes) >= 1 do
    <<
      rest::binary
    >> = report_data

    {:ok,
     %{
       id: report_id
     }, rest}
  end

  defp parse_report(report, channel) do
    Logger.warning("#{__MODULE__} unknown report and channel #{channel}: #{inspect(report)}")
    {:ok, nil, nil}
  end

  def parse_header_bytes(<<0, 0, 0, 0>>) do
    {:ok, nil}
  end

  def parse_header_bytes(
        <<cargo_length_lsb::8, cargo_length_msb::8, channel::integer-size(8),
          sequence_number::integer-size(8)>>
      ) do
    continuation = cargo_length_msb &&& 0b10000000
    cargo_length = (cargo_length_msb &&& 0b01111111) <<< 8 ||| cargo_length_lsb

    {:ok,
     %{
       cargo_length: cargo_length,
       continuation: continuation > 0,
       channel: channel,
       sequence_number: sequence_number
     }}
  end

  def parse_header_bytes(_) do
    :error
  end

  def parse_reports(report_bytes, channel, reports \\ []) do
    case parse_report(report_bytes, channel) do
      {:ok, report, ""} ->
        {:ok, reports ++ [report]}

      {:ok, nil, _} ->
        {:ok, reports}

      {:ok, report, next_report_bytes} ->
        parse_reports(next_report_bytes, channel, reports ++ [report])
    end
  end

  def parse_cargo(cargo_bytes) do
    <<chb1::8, chb2::8, chb3::8, chb4::8, report_bytes::binary>> = cargo_bytes
    {:ok, header} = parse_header_bytes(<<chb1::8, chb2::8, chb3::8, chb4::8>>)

    case header.channel do
      @shtp_command_channel ->
        Logger.debug("#{__MODULE__} skip cargo on channel 0")
        {:ok, nil}

      channel ->
        {:ok, reports} = parse_reports(report_bytes, channel)

        {:ok,
         %{
           header: header,
           reports: reports
         }}
    end
  end

  @impl GenServer
  def handle_info(:verify_chip_ready, %{chip_ready?: true} = state), do: {:noreply, state}

  def handle_info(:verify_chip_ready, state) do
    Logger.error("#{__MODULE__} reset response missing; retrying reset")
    handle_cast(:reset, state)
  end

  def handle_info(:verify_enables, state) do
    missing = missing_sensors(state, System.monotonic_time(:nanosecond))
    state = %{state | verify_ref: nil}

    cond do
      state.requested_enables == [] ->
        {:noreply, state}

      missing == [] ->
        {:noreply, schedule_enable_verify(%{state | enable_attempts: 0})}

      state.enable_attempts >= @max_enable_attempts ->
        Logger.error("#{__MODULE__} sensor streams missing #{inspect(missing)}; resetting")
        handle_cast(:reset, state)

      true ->
        Logger.warning("#{__MODULE__} enabling missing sensor streams #{inspect(missing)}")
        state = Enum.reduce(missing, state, &send_enable(&2, &1))
        {:noreply, schedule_enable_verify(%{state | enable_attempts: state.enable_attempts + 1})}
    end
  end

  def handle_info(:loop, state) do
    state = drain_packets(state, state.max_packets_per_poll)
    Process.send_after(self(), :loop, state.poll_interval_ms)
    {:noreply, state}
  end

  defp drain_packets(state, 0), do: state

  defp drain_packets(state, remaining) do
    received_at_ns = System.monotonic_time(:nanosecond)

    with {:ok, header_bytes} <- state.transport.read(state.i2c, @address, 4),
         {:ok, %{cargo_length: length}} when length > 4 and length <= 4096 <-
           parse_header_bytes(header_bytes),
         {:ok, cargo_bytes} <- state.transport.read(state.i2c, @address, length),
         true <- byte_size(cargo_bytes) == length,
         {:ok, cargo} <- parse_cargo(cargo_bytes) do
      state = if cargo, do: handle_cargo(state, cargo, received_at_ns), else: state
      drain_packets(state, remaining - 1)
    else
      {:ok, nil} ->
        state

      _failure ->
        state
    end
  end

  @doc false
  def handle_cargo(
        state,
        %{header: %{channel: @inport_sensor_reports_channel}, reports: reports},
        received_at_ns
      )
      when state.chip_ready? do
    {state, _reference_delta} =
      Enum.reduce(reports, {state, 0}, fn report, {state, reference_delta} ->
        case report do
          %{id: @timebase_reference_report, base_delta: delta} ->
            {state, -delta}

          %{id: 0xFA, base_delta: delta} ->
            {state, reference_delta + delta}

          %{id: id} when id in @imu_sample_ids ->
            {receive_sample(state, report, received_at_ns, reference_delta), reference_delta}

          _ ->
            {state, reference_delta}
        end
      end)

    state
  end

  def handle_cargo(
        state,
        %{header: %{channel: @executable_channel}, reports: reports},
        _received_at_ns
      ) do
    if Enum.any?(reports, &(&1.id == @reset_complete_response)) do
      if state.ready_ref, do: Process.cancel_timer(state.ready_ref)
      sensors = Enum.uniq(state.requested_enables ++ state.pending_enables)

      state = %{
        state
        | chip_ready?: true,
          pending_enables: [],
          requested_enables: sensors,
          last_reports: %{},
          reference: make_ref(),
          enable_attempts: 0,
          ready_ref: nil,
          channel_sequences: %{}
      }

      state = Enum.reduce(sensors, state, &send_enable(&2, &1))
      schedule_enable_verify(state)
    else
      state
    end
  end

  def handle_cargo(state, _cargo, _received_at_ns), do: state

  defp receive_sample(state, report, received_at_ns, reference_delta) do
    previous = state.last_reports[report.id]

    if previous && previous.sequence == report.sequence_number do
      state
    else
      delay_ticks = ((report.status &&& 0xFC) <<< 6) + report.delay

      captured_at_ns =
        min(received_at_ns, received_at_ns + (reference_delta + delay_ticks) * 100_000)

      sample = %{
        build_sample(report)
        | captured_at_ns: captured_at_ns,
          received_at_ns: received_at_ns,
          accuracy: report.status &&& 3,
          sequence: report.sequence_number,
          reference: state.reference
      }

      Enum.each(state.listeners, &GenServer.cast(&1, {:imu_sample, sample}))

      %{
        state
        | last_reports:
            Map.put(state.last_reports, report.id, %{
              at_ns: captured_at_ns,
              sequence: report.sequence_number
            })
      }
    end
  end

  @doc false
  def missing_sensors(state, now_ns) do
    Enum.reject(state.requested_enables, fn sensor ->
      report = state.last_reports[report_id(sensor)]
      report && now_ns - report.at_ns <= state.stream_timeout_ms * 1_000_000
    end)
  end

  @doc false
  def build_sample(%{id: id, x: x, y: y, z: z}) when id == @accelerometer_report do
    %Sample{
      kind: :acceleration,
      x: x * @accelerometer_scale,
      y: y * @accelerometer_scale,
      z: z * @accelerometer_scale
    }
  end

  def build_sample(%{id: id, x: x, y: y, z: z}) when id == @calibrated_gyroscope_report do
    %Sample{
      kind: :angular_velocity,
      x: x * @gyroscope_scale,
      y: y * @gyroscope_scale,
      z: z * @gyroscope_scale
    }
  end

  def build_sample(%{id: id, i: i, j: j, k: k, real: real})
      when id == @game_rotation_vector_report do
    %Sample{
      kind: :rotation,
      x: i * @quaternion_scale,
      y: j * @quaternion_scale,
      z: k * @quaternion_scale,
      w: real * @quaternion_scale
    }
  end

  def build_sample(_), do: nil

  defp schedule_enable_verify(state) do
    if state.verify_ref, do: Process.cancel_timer(state.verify_ref)
    %{state | verify_ref: Process.send_after(self(), :verify_enables, @enable_verify_ms)}
  end

  defp report_id(:accelerometer), do: @accelerometer_report
  defp report_id(:uncalibrated_gyroscope), do: @uncalibrated_gyroscope_report
  defp report_id(:calibrated_gyroscope), do: @calibrated_gyroscope_report
  defp report_id(:game_rotation_vector), do: @game_rotation_vector_report

  defp send_enable(state, sensor) do
    send_command(
      state,
      @sensor_hub_control_channel,
      <<@set_feature_request, report_id(sensor), 0, 0, 0,
        state.report_interval_us::little-unsigned-32, 0::64>>
    )
  end

  defp send_command(state, channel, payload) do
    sequence = Map.get(state.channel_sequences, channel, 0)
    cargo_length = byte_size(payload) + 4
    cargo = <<cargo_length::little-16, channel, sequence, payload::binary>>

    case state.transport.write(state.i2c, @address, cargo) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("#{__MODULE__} I2C write failed: #{inspect(reason)}")
    end

    %{
      state
      | channel_sequences: Map.put(state.channel_sequences, channel, rem(sequence + 1, 256))
    }
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    if state.verify_ref, do: Process.cancel_timer(state.verify_ref)
    if state.ready_ref, do: Process.cancel_timer(state.ready_ref)
    state = send_command(state, @executable_channel, <<0x01>>)

    {:noreply,
     %{
       state
       | chip_ready?: false,
         last_reports: %{},
         reference: make_ref(),
         verify_ref: nil,
         ready_ref: Process.send_after(self(), :verify_chip_ready, @chip_ready_timeout_ms)
     }}
  end

  @impl GenServer
  def handle_cast(:request_product_id, state) do
    {:noreply, send_command(state, @sensor_hub_control_channel, <<@product_id_request, 0x00>>)}
  end

  @impl GenServer
  def handle_cast({:enable, sensor}, state) do
    if state.chip_ready? do
      state = send_enable(state, sensor)

      state = %{
        state
        | requested_enables: Enum.uniq(state.requested_enables ++ [sensor]),
          enable_attempts: 0
      }

      {:noreply, schedule_enable_verify(state)}
    else
      {:noreply, %{state | pending_enables: state.pending_enables ++ [sensor]}}
    end
  end

  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  @impl OvcsDrivers.Imu
  def enable do
    :ok = GenServer.cast(__MODULE__, {:enable, :accelerometer})
    :ok = GenServer.cast(__MODULE__, {:enable, :calibrated_gyroscope})
    :ok = GenServer.cast(__MODULE__, {:enable, :game_rotation_vector})
    :ok
  end

  def request_product_id do
    :ok = GenServer.cast(__MODULE__, :request_product_id)
    :ok
  end

  @impl OvcsDrivers.Imu
  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end
end
