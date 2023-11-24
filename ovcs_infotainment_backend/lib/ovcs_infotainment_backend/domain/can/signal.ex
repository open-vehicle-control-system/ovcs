defmodule OvcsInfotainmentBackend.Can.Signal do
  defstruct [
    :name,
    :value,
    :unit,
    :origin,
    kind: "integer"
  ]

  def from_frame_for_compiled_spec(frame, compiled_signal_spec) do
    signal = %OvcsInfotainmentBackend.Can.Signal{
      name: compiled_signal_spec.name,
      kind: compiled_signal_spec.kind,
      unit: compiled_signal_spec.unit,
      origin: compiled_signal_spec.origin,
      value: nil
    }
    bytes = :binary.part(frame.raw_data, compiled_signal_spec.start_byte, compiled_signal_spec.byte_number)
    number = case compiled_signal_spec.endianness do
      "little" ->
        <<val::little-integer-size(8 * compiled_signal_spec.byte_number)>> = bytes
        val
      "big"    ->
        <<val::big-integer-size(8 * compiled_signal_spec.byte_number)>> = bytes
        val
    end
    value = case compiled_signal_spec.kind do
      "integer" -> (number * compiled_signal_spec.scale) + compiled_signal_spec.offset
      _        -> compiled_signal_spec.mapping[number]
    end
    {:ok, %{signal | value: value}}
  end
end
