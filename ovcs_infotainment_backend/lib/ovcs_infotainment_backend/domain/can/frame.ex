defmodule OvcsInfotainmentBackend.Can.Frame do
  defstruct [:id, :data_length, :raw_data]

  def to_string(frame) do
    "#{frame.id}(0x#{id_hex(frame)})  [#{frame.data_length}]  #{raw_data_hex(frame)}"
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
end
