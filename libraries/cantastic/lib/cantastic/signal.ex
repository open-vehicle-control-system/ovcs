defmodule Cantastic.Signal do
  defstruct [
    :name,
    :frame_name,
    :value,
    :unit,
    :origin,
    kind: "integer"
  ]

  def to_string(signal) do
    "[Signal] #{signal.frame_name}.#{signal.name} = #{signal.value}"
  end

  def from_frame_for_specification(frame, signal_specification) do
    signal = %Cantastic.Signal{
      name: signal_specification.name,
      frame_name: signal_specification.frame_name,
      kind: signal_specification.kind,
      unit: signal_specification.unit,
      origin: signal_specification.origin,
      value: nil
    }
    raw_data            = frame.raw_data
    raw_data_bit_length = frame.data_length * 8
    head_length         = signal_specification.value_start
    value_length        = signal_specification.value_length
    tail_length         = raw_data_bit_length - head_length - value_length

    value = case signal_specification.kind do
      "integer" ->
        number = case signal_specification.endianness do
          "little" ->
            try do
              <<_head::size(head_length), val::little-integer-size(value_length), _tail::size(tail_length)>> = raw_data
              val
            rescue
              error in MatchError ->
                {:error, error}
            end
          "big"    ->
            <<_head::size(head_length), val::big-integer-size(value_length), _tail::size(tail_length)>> = raw_data
            val
        end
        Float.round((number * signal_specification.scale) + signal_specification.offset, signal_specification.decimals)
      _ ->
        <<_head::size(head_length), val::bitstring-size(value_length), _tail::size(tail_length)>> = raw_data
        signal_specification.mapping[val]
    end
    {:ok, %{signal | value: value}}
  end
end
