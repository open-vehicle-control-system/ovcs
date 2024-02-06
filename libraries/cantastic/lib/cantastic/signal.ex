defmodule Cantastic.Signal do
  defstruct [
    :name,
    :value,
    :unit,
    :origin,
    kind: "integer"
  ]

  def to_string(signal) do
    "[Signal] #{signal.name} = #{signal.value}"
  end

  def from_frame_for_compiled_spec(frame, compiled_signal_spec) do
    signal = %Cantastic.Signal{
      name: compiled_signal_spec.name,
      kind: compiled_signal_spec.kind,
      unit: compiled_signal_spec.unit,
      origin: compiled_signal_spec.origin,
      value: nil
    }
    raw_data            = frame.raw_data
    raw_data_bit_length = frame.data_length * 8
    head_length         = compiled_signal_spec.value_start
    value_length        = compiled_signal_spec.value_length
    tail_length         = raw_data_bit_length - head_length - value_length
    number = case compiled_signal_spec.endianness do
      "little" ->
        <<_head::size(head_length), val::little-integer-size(value_length), _tail::size(tail_length)>> = raw_data
        val
      "big"    ->
        <<_head::size(head_length), val::big-integer-size(value_length), _tail::size(tail_length)>> = raw_data
        val
    end
    value = case compiled_signal_spec.kind do
      "integer" -> Float.round((number * compiled_signal_spec.scale) + compiled_signal_spec.offset, compiled_signal_spec.decimals)
      _        -> compiled_signal_spec.mapping[number]
    end
    {:ok, %{signal | value: value}}
  end
end
