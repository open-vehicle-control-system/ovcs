defmodule Cantastic.Frame do
  alias Cantastic.{Util, Interface}
  defstruct [:id, :data_length, :raw_data]

  def to_string(frame) do
    "[Frame] #{format_id(frame)}  [#{frame.data_length}]  #{format_data(frame)}"
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

  def send(network_name, hex_id, hex_data) do
    id        = hex_id |> Util.hex_to_integer()
    raw_data  = Util.hex_to_bin(hex_data)
    raw_frame = Util.raw_frame(id, raw_data)
    Interface.send_raw_frame(network_name, raw_frame)
  end
end
