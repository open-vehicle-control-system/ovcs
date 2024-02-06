defmodule Cantastic.Frame do
  alias Cantastic.{Util, Interface}

  defstruct [:id, :data_length, :raw_data, :network_name]

  def build(id_hex: id_hex, network_name: network_name, data_hex: data_hex) do
    raw_data = data_hex |> Cantastic.Util.hex_to_bin()
    %Cantastic.Frame{
      id: id_hex |> Cantastic.Util.hex_to_integer(),
      network_name: network_name,
      raw_data: raw_data,
      data_length: byte_size(raw_data) * 8
    }
  end
  def build(id: id, network_name: network_name, raw_data: raw_data, data_length: data_length) do
    %Cantastic.Frame{
      id: id,
      network_name: network_name,
      raw_data: raw_data,
      data_length: data_length
    }
  end

  def send(frame) do
    Interface.send_raw_frame(frame.network_name, to_bin(frame))
  end

  def send_hex(network_name, id_hex, data_hex) do
    frame = build(id_hex: id_hex, network_name: network_name, data_hex: data_hex)
    send(frame)
  end

  def to_string(frame) do
    "[Frame] #{frame.network_name} - #{format_id(frame)}  [#{frame.data_length}]  #{format_data(frame)}"
  end

  def format_id(frame) do
    frame.id |> Util.integer_to_hex()
  end

  def format_data(frame) do
    frame.raw_data
    |> Util.bin_to_hex()
    |> String.split("", trim: true)
    |> Enum.chunk_every(2)
    |> Enum.join(" ")
  end

  def to_bin(frame) do
    padding     = 8 - frame.data_length
    << frame.id::little-integer-size(16),
      0::2 * 8,
      frame.data_length,
      0::3 * 8
    >> <>
    frame.raw_data <>
    <<0::padding * 8>>
  end

end
