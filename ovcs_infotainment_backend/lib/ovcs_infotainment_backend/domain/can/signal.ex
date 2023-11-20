defmodule OvcsInfotainmentBackend.Can.Signal do
  alias OvcsInfotainmentBackend.Can.Frame

  defstruct [
    :name,
    :kind,
    :value,
    :unit,
    :emitter
  ]

  def from_frame(%Frame{} = frame, name, start \\ 0, length \\ 1, kind \\ :integer, offset \\ 0, scale \\ 1, endianness \\ :little, mapping \\ nil, emitter \\ nil, unit \\ nil) do
    signal = %OvcsInfotainmentBackend.Can.Signal{
      name: name,
      kind: kind,
      unit: unit,
      emitter: emitter,
      value: nil
    }
    bytes = :binary.part(frame.raw_data, start, length)
    number = case endianness do
      :little ->
        <<val::little-integer-size(8 * length)>> = bytes
        val
      :big    ->
        <<val::big-integer-size(8 * length)>> = bytes
        val
    end
    value = case kind do
      :integer -> (number * scale) + offset
      _        -> mapping[number]
    end
    {:ok, %{signal | value: value}}
  end
end
