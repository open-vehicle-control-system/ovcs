defmodule Cantastic.SignalSpecification do
  alias Cantastic.Util

  defstruct [
    :name,
    :kind,
    :frame_id,
    :frame_name,
    :value_start,
    :value_length,
    :endianness,
    :mapping,
    :reverse_mapping,
    :unit,
    :scale,
    :offset,
    :sign,
    :value
  ]

  def from_signal_specification(frame_id, frame_name, yaml_signal_specification) do
    value_length         = yaml_signal_specification.value_length
    signal_specification = %Cantastic.SignalSpecification{
      name: yaml_signal_specification.name,
      frame_id: frame_id,
      frame_name: frame_name,
      kind: yaml_signal_specification[:kind] || "integer",
      sign: yaml_signal_specification[:sign] || "unsigned",
      value_start: yaml_signal_specification.value_start,
      value_length: value_length,
      endianness: yaml_signal_specification[:endianness] || "little",
      mapping: compute_mapping(yaml_signal_specification[:mapping], value_length),
      reverse_mapping: compute_reverse_mapping(yaml_signal_specification[:mapping], value_length),
      unit: yaml_signal_specification[:unit],
      scale: (yaml_signal_specification[:scale] || 1) + 0.0,
      offset: yaml_signal_specification[:offset] || 0,
      value: yaml_signal_specification[:value] |> Util.integer_to_bin_big(value_length)
    }
    {:ok, signal_specification}
  end

  def instantiate_raw(raw_data, signal_specification, value) do
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

  defp compute_mapping(nil, _value_length), do: nil
  defp compute_mapping(mapping, value_length) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_key, computed_mapping) ->
      key = atom_key |> Atom.to_string() |> Util.string_to_integer() |>  Util.integer_to_bin_big(value_length)
      computed_mapping |> Map.put(key, mapping[atom_key])
    end)
  end

  defp compute_reverse_mapping(nil, _value_length), do: nil
  defp compute_reverse_mapping(mapping, value_length) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_value, computed_mapping) ->
      string_value = atom_value |> Atom.to_string()
      value        = string_value |> Util.string_to_integer() |> Util.integer_to_bin_big(value_length)
      computed_mapping |> Map.put(mapping[atom_value], value)
    end)
  end
end
