defmodule Cantastic.Frame do
  alias Cantastic.{Util, Interface}
  defstruct [:id, :data_length, :raw_data]

  def to_string(frame) do
    "[Frame] #{id_hex(frame)}  [#{frame.data_length}]  #{raw_data_hex(frame)}"
  end

  def id_hex(frame) do
    frame.id |> Integer.to_string(16)
  end

  def raw_data_hex(frame) do
    frame.raw_data
    |> Base.encode16()
    |> String.split("", trim: true)
    |> Enum.chunk_every(2)
    |> Enum.join(" ")
  end

  def send(network_name, hex_id, hex_data) do
    id              = hex_id |> String.to_integer(16)
    {:ok, raw_data} = Base.decode16(hex_data)
    raw_frame       = Util.raw_frame(id, raw_data)
    Interface.send_raw_frame(network_name, raw_frame)
  end
end
