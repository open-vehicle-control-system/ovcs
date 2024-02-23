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
    :origin,
    :scale,
    :offset,
    :decimals,
    :value
  ]

  def from_signal_specification(frame_id, frame_name, yaml_signal_specification) do
    signal_specification = %Cantastic.SignalSpecification{
      name: yaml_signal_specification.name,
      frame_id: frame_id,
      frame_name: frame_name,
      kind: yaml_signal_specification[:kind] || "integer",
      value_start: yaml_signal_specification.value_start,
      value_length: yaml_signal_specification.value_length,
      endianness: yaml_signal_specification[:endianness] || "little",
      mapping: compute_mapping(yaml_signal_specification[:mapping]),
      reverse_mapping: compute_reverse_mapping(yaml_signal_specification[:mapping]),
      unit: yaml_signal_specification[:unit],
      origin: yaml_signal_specification[:origin],
      scale: (yaml_signal_specification[:scale] || 1) + 0.0,
      offset: yaml_signal_specification[:offset] || 0,
      decimals: yaml_signal_specification[:decimals] || 0,
      value: yaml_signal_specification[:value] |> Util.unsigned_integer_to_bin_big()
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
      _ -> signal_specification.reverse_mapping[value]
    end
  end

  defp compute_mapping(nil), do: nil
  defp compute_mapping(mapping) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_key, computed_mapping) ->
      string_key = atom_key |> Atom.to_string()
      key        = Util.string_to_integer(string_key)
      computed_mapping |> Map.put(key, mapping[atom_key])
    end)
  end

  defp compute_reverse_mapping(nil), do: nil
  defp compute_reverse_mapping(mapping) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_value, computed_mapping) ->
      string_value = atom_value |> Atom.to_string()
      value        = string_value |> Util.string_to_integer() |> Util.unsigned_integer_to_bin_big()
      computed_mapping |> Map.put(mapping[atom_value], value)
    end)
  end
end
