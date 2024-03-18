defmodule Cantastic.Signal do
  defstruct [
    :name,
    :frame_name,
    :value,
    :unit,
    :kind
  ]

  def to_string(signal) do
    "[Signal] #{signal.frame_name}.#{signal.name} = #{signal.value}"
  end

  def build_raw(raw_data, signal_specification, value) do
    value = case is_function(value, 1) do
      true -> value.(raw_data)
      false -> value
    end
    case signal_specification.kind do
      "static" -> signal_specification.value
      "integer" ->
        int = round((value / signal_specification.scale) - signal_specification.offset)
        case signal_specification.endianness do
          "little" ->
            <<int::little-integer-size(signal_specification.value_length)>>
          "big"    ->
            <<int::big-integer-size(signal_specification.value_length)>>
        end
      "enum" -> signal_specification.reverse_mapping[value]
    end
  end

  def interpret(frame, signal_specification) do
    signal = %Cantastic.Signal{
      name: signal_specification.name,
      frame_name: signal_specification.frame_name,
      kind: signal_specification.kind,
      unit: signal_specification.unit,
      value: nil
    }
    raw_data            = frame.raw_data
    raw_data_bit_length = frame.data_length * 8
    head_length         = signal_specification.value_start
    value_length        = signal_specification.value_length
    tail_length         = raw_data_bit_length - head_length - value_length

    try do
      value = case signal_specification.kind do
        "static" ->
          <<_head::size(head_length), val::bitstring-size(value_length), _tail::size(tail_length)>> = raw_data
          val
        "integer" ->
            int = case {signal_specification.endianness, signal_specification.sign} do
              {"little", "signed"} ->
                <<_head::size(head_length), val::little-signed-integer-size(value_length), _tail::size(tail_length)>> = raw_data
                val
              {"little", "unsigned"} ->
                <<_head::size(head_length), val::little-unsigned-integer-size(value_length), _tail::size(tail_length)>> = raw_data
                val
              {"big", "signed"} ->
                <<_head::size(head_length), val::big-signed-integer-size(value_length), _tail::size(tail_length)>> = raw_data
                val
              {"big", "unsigned"} ->
                <<_head::size(head_length), val::big-unsigned-integer-size(value_length), _tail::size(tail_length)>> = raw_data
                val
            end

          round((int * signal_specification.scale) + signal_specification.offset)
        "enum" ->
          <<_head::size(head_length), val::bitstring-size(value_length), _tail::size(tail_length)>> = raw_data
          signal_specification.mapping[val]
      end
      {:ok, %{signal | value: value}}
    rescue
      error in MatchError ->
        {:error, error}
    end
  end
end
