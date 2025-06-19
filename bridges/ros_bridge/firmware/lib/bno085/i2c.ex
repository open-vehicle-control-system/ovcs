defmodule BNO085.I2C do
  use GenServer
  import Bitwise
  require Logger

  @address 0x4A
  @product_id_request 0xF9
  @product_id_response 0xF8
  @set_feature_request 0xFD
  @timebase_reference_report 0xFB
  @accelerometer_report 0x01
  @calibrated_gyroscope_report 0x02
  @uncalibrated_gyroscope_report 0x07
  @command_reponse 0xF1
  @shtp_command_channel 0x00
  @executable_channel 0x01
  @sensor_hub_control_channel 0x02
  @inport_sensor_reports_channel 0x03
  @wake_inport_sensor_reports_channel 0x04
  @gyro_rotation_vector_channel 0x05
  @published_report_ids [@accelerometer_report , @calibrated_gyroscope_report, @uncalibrated_gyroscope_report]

  @impl true
  def init(_args) do
    {:ok, i2c} = Circuits.I2C.open("i2c-1")
    :ok = GenServer.cast(self(), :reset)
    {:ok, _} = :timer.send_interval(10, :loop)
    {:ok, %{
      i2c: i2c,
      listeners: []
    }}
  end

  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @inport_sensor_reports_channel)
  when report_id == @calibrated_gyroscope_report and bit_size(report_bytes) >= 10*8 do
    <<
      sequence_number::8,
      status::8,
      delay::8,
      calibrated_axis_x::little-signed-integer-size(16),
      calibrated_axis_y::little-signed-integer-size(16),
      calibrated_axis_z::little-signed-integer-size(16),
      rest::binary
    >> = report_data
    {:ok, %{
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
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @inport_sensor_reports_channel)
  when report_id == @uncalibrated_gyroscope_report and bit_size(report_bytes) >= 16*8 do
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
    {:ok, %{
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
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @inport_sensor_reports_channel)
  when report_id == @timebase_reference_report and bit_size(report_bytes) >= 4 * 8  do
    <<
      base_delta::little-integer-size(32),
      rest::binary
    >> = report_data
    {:ok, %{
      id: report_id,
      base_delta: base_delta
    }, rest}
  end
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @inport_sensor_reports_channel)
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
    {:ok, %{
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
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @sensor_hub_control_channel)
  when report_id == @command_reponse and bit_size(report_bytes) >= 16*8 do
    <<
      sequence_number,
      command,
      command_sequence_number,
      response_sequence_number,
      _0::8, _1::8, _2::8, _3::8, _4::8, _5::8, _6::8, _7::8, _8::8, _9::8, _10::8,
      rest::binary
    >> = report_data
    {:ok, %{
      id: report_id,
      sequence_number: sequence_number,
      command: command,
      command_sequence_number: command_sequence_number,
      response_sequence_number: response_sequence_number
    }, rest}
  end
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @sensor_hub_control_channel)
  when report_id == @product_id_response and bit_size(report_bytes) >= 16 do
    <<
      reset_cause,
      sw_version_major,
      sw_version_minor,
      sw_part_number::little-integer-size(32),
      sw_build_number::little-integer-size(32),
      sw_patch::little-integer-size(16),
      _0::8, _1::8,
      rest::binary
    >> = report_data
    {:ok, %{
      id: report_id,
      name: "product_id_response",
      reset_cause: reset_cause,
      part_number: sw_part_number,
      software_version: "#{sw_version_major}.#{sw_version_minor}.#{sw_patch}",
      build_number: sw_build_number
    }, rest}
  end
  defp parse_report(<< report_id::integer, report_data::binary >> = report_bytes, @executable_channel)
  when bit_size(report_bytes) >= 1 do
    <<
      rest::binary
    >> = report_data
    {:ok, %{
      id: report_id
    }, rest}
  end
  defp parse_report(report, channel) do
    Logger.warning("#{__MODULE__} unknown report and channel #{channel}: #{inspect report}")
    {:ok, nil, nil}
  end

  def parse_header_bytes(<< 0, 0, 0, 0 >>) do
    {:ok, nil}
  end
  def parse_header_bytes(<< cargo_length_lsb::8, cargo_length_msb::8, channel::integer-size(8), sequence_number::integer-size(8) >>) do
    continuation = cargo_length_msb &&& 0b10000000
    cargo_length = ((cargo_length_msb &&& 0b01111111) <<< 8) ||| cargo_length_lsb
    {:ok,
      %{
        cargo_length: cargo_length,
        continuation: continuation > 0,
        channel: channel,
        sequence_number: sequence_number
      }
    }
  end
  def parse_header_bytes(_) do
    :error
  end

  def parse_reports(report_bytes, channel, reports \\ []) do
    case parse_report(report_bytes, channel) do
      {:ok, report, ""} -> {:ok, reports ++ [report]}
      {:ok, nil, _} -> {:ok, reports}
      {:ok, report, next_report_bytes} -> parse_reports(next_report_bytes, channel, reports ++ [report])
    end
  end

  def parse_cargo(cargo_bytes) do
    << chb1::8, chb2::8, chb3::8, chb4::8, report_bytes::binary >> = cargo_bytes
    {:ok, header} = parse_header_bytes(<< chb1::8, chb2::8, chb3::8, chb4::8 >>)
    case header.channel do
      @shtp_command_channel ->
        Logger.debug("#{__MODULE__} skip cargo on channel 0")
        {:ok, nil}
      channel ->
        {:ok, reports} = parse_reports(report_bytes, channel)
        {:ok, %{
          header: header,
          reports: reports
        }}
    end
  end

  @impl true
  def handle_info(:loop, state) do
    with {:ok, header_bytes } <- Circuits.I2C.read(state.i2c, @address, 4) do
      case parse_header_bytes(header_bytes) do
        {:ok, nil} ->
          {:noreply, state}
        {:ok, %{cargo_length: cargo_length} = _header} when cargo_length > 0 ->
          {:ok, cargo_bytes} = Circuits.I2C.read(state.i2c, @address, cargo_length)
          {:ok, cargo} = parse_cargo(cargo_bytes)
          case cargo do
            nil ->
              Logger.warning("#{__MODULE__} skip empty cargo")
            _ ->
              Logger.debug("#{__MODULE__} cargo #{inspect cargo}")
              cargo.reports |> Enum.each(fn report ->
                if Enum.member?(@published_report_ids, report.id) && cargo.header.channel == @inport_sensor_reports_channel do
                  state.listeners |> Enum.each(fn listener ->
                    GenServer.cast(listener, {:bno085_sensor_message, report})
                  end)
                end
              end)
          end

          {:noreply, state}
        _ ->
          Logger.error("#{__MODULE__} header parsing error: #{header_bytes}")
          {:noreply, state}
      end
    else
      {:error, error} ->
        Logger.error("#{__MODULE__} I2C error: #{error |> inspect}")
        {:noreply, state}
    end
  end

  def send_command(state, channel, data) do
    cargo_length = byte_size(data) + 4
    << cargo_length_msb::8, cargo_length_lsb::8 >> = << cargo_length::16 >>
    sequence_number = 0x01
    cargo = << cargo_length_lsb, cargo_length_msb, channel, sequence_number, data::binary>>
    Logger.debug("#{__MODULE__} send command #{inspect cargo}")
    Circuits.I2C.write(state.i2c, @address, cargo)
  end

  @impl true
  def handle_cast(:reset, state) do
    send_command(state, @executable_channel, << 0x01 >>)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:request_product_id, state) do
    send_command(state, @sensor_hub_control_channel, << @product_id_request, 0x00 >> )
    {:noreply, state}
  end

  @impl true
  def handle_cast({:enable, sensor}, state) do
    report_id = case sensor do
      :accelerometer -> @accelerometer_report
      :uncalibrated_gyroscope -> @uncalibrated_gyroscope_report
      :calibrated_gyroscope -> @calibrated_gyroscope_report
    end
    Logger.debug("#{__MODULE__} enable #{sensor}")
    send_command(state, @sensor_hub_control_channel, << @set_feature_request, report_id, 0x00, 0x00, 0x00, 0x60, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 >>)
    {:noreply, state}
  end

  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def enable_all_sensors do
    :ok = GenServer.cast(__MODULE__, {:enable, :accelerometer})
    :ok = GenServer.cast(__MODULE__, {:enable, :uncalibrated_gyroscope})
    :ok = GenServer.cast(__MODULE__, {:enable, :calibrated_gyroscope})
    :ok
  end

  def request_product_id do
    :ok = GenServer.cast(__MODULE__, :request_product_id)
    :ok
  end

  def register_listener(listener) do
    GenServer.cast(__MODULE__, {:register_listener, listener})
  end
end
