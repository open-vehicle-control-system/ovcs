defmodule Cantastic.CompiledSignalSpec do
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

  def from_signal_spec(frame_id, frame_name, signal_spec) do
    compiled_signal_spec = %Cantastic.CompiledSignalSpec{
      name: signal_spec.name,
      frame_id: frame_id,
      frame_name: frame_name,
      kind: signal_spec[:kind] || "integer",
      value_start: signal_spec.value_start,
      value_length: signal_spec.value_length,
      endianness: signal_spec[:endianness] || "little",
      mapping: compile_mapping(signal_spec[:mapping]),
      reverse_mapping: compile_reverse_mapping(signal_spec[:mapping]),
      unit: signal_spec[:unit],
      origin: signal_spec[:origin],
      scale: (signal_spec[:scale] || 1) + 0.0,
      offset: signal_spec[:offset] || 0,
      decimals: signal_spec[:decimals] || 0,
      value: signal_spec[:value] |> Util.unsigned_integer_to_bin_big()
    }
    {:ok, compiled_signal_spec}
  end

  def instantiate_raw(raw_data, compiled_signal_spec, value) do
    value = case is_function(value, 1) do
      true -> value.(raw_data)
      false -> value
    end
    case compiled_signal_spec.kind do
      "static" -> compiled_signal_spec.value
      "integer" ->
        int = round((value / compiled_signal_spec.scale) - compiled_signal_spec.offset)
        case compiled_signal_spec.endianness do
          "little" ->
            <<int::little-integer-size(compiled_signal_spec.value_length)>>
          "big"    ->
            <<int::big-integer-size(compiled_signal_spec.value_length)>>
        end
      _ -> compiled_signal_spec.reverse_mapping[value]
    end
  end

  defp compile_mapping(nil), do: nil
  defp compile_mapping(mapping) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_key, compiled_mapping) ->
      string_key = atom_key |> Atom.to_string()
      key = Util.string_to_integer(string_key)
      compiled_mapping |> Map.put(key, mapping[atom_key])
    end)
  end

  defp compile_reverse_mapping(nil), do: nil
  defp compile_reverse_mapping(mapping) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(atom_value, compiled_mapping) ->
      string_value = atom_value |> Atom.to_string()
      value =  string_value |> Util.string_to_integer() |> Util.unsigned_integer_to_bin_big()
      compiled_mapping |> Map.put(mapping[atom_value], value)
    end)
  end
end
